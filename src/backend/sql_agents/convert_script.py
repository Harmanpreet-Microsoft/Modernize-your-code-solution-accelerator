"""This module loops through each file in a batch and processes it using the SQL agents.
It sets up a group chat for the agents, sends the source script to the chat, and processes
the responses from the agents. It also reports in real-time to the client using websockets
and updates the database with the results.
"""

import asyncio
import json
import logging

from api.status_updates import send_status_update

from common.models.api import (
    FileProcessUpdate,
    FileRecord,
    FileResult,
    LogType,
    ProcessStatus,
)
from common.services.batch_service import BatchService

from semantic_kernel.contents import AuthorRole, ChatMessageContent

from sql_agents.agents.fixer.response import FixerResponse
from sql_agents.agents.migrator.response import MigratorResponse
from sql_agents.agents.picker.response import PickerResponse
from sql_agents.agents.semantic_verifier.response import SemanticVerifierResponse
from sql_agents.agents.syntax_checker.response import SyntaxCheckerResponse
from sql_agents.helpers.agents_manager import SqlAgents
from sql_agents.helpers.comms_manager import CommsManager
from sql_agents.helpers.models import AgentType

# Import Azure OpenAI specific exceptions
try:
    from openai import BadRequestError
    from azure.core.exceptions import HttpResponseError
except ImportError:
    BadRequestError = Exception
    HttpResponseError = Exception

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

# Constant prefix for sensitive content-related errors
CONTENT_SAFETY_PREFIX = "Sensitive or harmful content detected"


def is_content_safety_error(error: Exception) -> bool:
    """Check if an error is related to content safety filters"""
    error_str = str(error).lower()
    error_indicators = [
        'content filter',
        'content policy',
        'responsible ai',
        'harmful content',
        'inappropriate content',
        'safety filter',
        'content_filter',
        'responsibleaipolicy',
        'content violation'
    ]
    return any(indicator in error_str for indicator in error_indicators)


def has_harmful_content(content: str) -> bool:
    """Check if content contains harmful indicators"""
    harmful_indicators = [
        'child exploitation',
        'sexual content',
        'violent content',
        'harmful content',
        'inappropriate content',
        'content policy',
        'responsible ai',
        'content violation',
        'kill someone',
        'murder',
        'assassination',
        'weapon',
        'explosive',
        'poison',
        'harm',
        'violence'
    ]
    return any(term in content.lower() for term in harmful_indicators)


def prefix_if_harmful(content: str) -> str:
    """Add prefix to content if it contains harmful indicators"""
    if has_harmful_content(content):
        return f"{CONTENT_SAFETY_PREFIX}: {content}"
    return content


async def handle_content_safety_error(
    error: Exception,
    file: FileRecord,
    batch_service: BatchService,
    current_migration: str = "",
    agent_type: AgentType = AgentType.ALL
) -> None:
    """Handle content safety errors consistently"""
    logger.warning(f"Content safety filter triggered for file {file.file_id}: {str(error)}")

    error_message = f"{CONTENT_SAFETY_PREFIX}: {str(error)}"

    description = {
        "role": AuthorRole.ASSISTANT.value,
        "name": agent_type.value,
        "content": (
            f"I'm sorry, but I cannot assist with that request due to content policy restrictions. "
            f"{error_message}"
        ),
    }

    await batch_service.create_file_log(
        str(file.file_id),
        description,
        current_migration,
        LogType.ERROR,
        agent_type,
        AuthorRole.ASSISTANT,
    )

    send_status_update(
        status=FileProcessUpdate(
            file.batch_id,
            file.file_id,
            ProcessStatus.COMPLETED,
            agent_type,
            f"{CONTENT_SAFETY_PREFIX} - Request blocked by content safety filters: {str(error)}",
            FileResult.ERROR,
        ),
    )


async def convert_script(
    source_script,
    file: FileRecord,
    batch_service: BatchService,
    sql_agents: SqlAgents,
) -> str:
    """Use the team of agents to migrate a sql script."""
    logger.info("Migrating query: %s\n", source_script)

    chat = CommsManager(sql_agents.idx_agents).group_chat

    send_status_update(
        status=FileProcessUpdate(
            file.batch_id,
            file.file_id,
            ProcessStatus.IN_PROGRESS,
            AgentType.ALL,
            "File processing started",
            file_result=FileResult.INFO,
        ),
    )

    current_migration = "No migration"
    is_complete: bool = False
    while not is_complete:
        try:
            await chat.add_chat_message(
                ChatMessageContent(role=AuthorRole.USER, content=source_script)
            )
            carry_response = None

            async for response in chat.invoke():
                await asyncio.sleep(5)
                carry_response = response

                if response.role == AuthorRole.ASSISTANT.value:
                    try:
                        match response.name:
                            case AgentType.MIGRATOR.value:
                                result = MigratorResponse.model_validate_json(response.content or "")
                                if result.input_error or result.rai_error:
                                    # Extract input_summary from the JSON response
                                    try:
                                        parsed_response = json.loads(response.content or "{}")
                                        input_summary = parsed_response.get("input_summary", "")
                                        formatted_content = f"{CONTENT_SAFETY_PREFIX}: {input_summary}" if input_summary else f"{CONTENT_SAFETY_PREFIX}: {response.content}"
                                    except json.JSONDecodeError:
                                        formatted_content = f"{CONTENT_SAFETY_PREFIX}: {response.content}"
                                    
                                    description = {
                                        "role": response.role,
                                        "name": response.name or "*",
                                        "content": formatted_content,
                                    }
                                    await batch_service.create_file_log(
                                        str(file.file_id),
                                        description,
                                        current_migration,
                                        LogType.ERROR,
                                        AgentType(response.name),
                                        AuthorRole(response.role),
                                    )
                                    
                                    # Send error status update
                                    send_status_update(
                                        status=FileProcessUpdate(
                                            file.batch_id,
                                            file.file_id,
                                            ProcessStatus.COMPLETED,
                                            AgentType.MIGRATOR,
                                            "Migration failed due to input or content policy error",
                                            FileResult.ERROR,
                                        ),
                                    )
                                    current_migration = None
                                    break
                            case AgentType.SYNTAX_CHECKER.value:
                                result = SyntaxCheckerResponse.model_validate_json(
                                    response.content.lower() or ""
                                )
                                if result.syntax_errors == []:
                                    chat.history.add_message(
                                        ChatMessageContent(
                                            role=AuthorRole.USER,
                                            name="candidate",
                                            content=(
                                                f"source_script: {source_script}, \n "
                                                + f"migrated_script: {current_migration}"
                                            ),
                                        )
                                    )
                            case AgentType.PICKER.value:
                                result = PickerResponse.model_validate_json(response.content or "")
                                current_migration = result.picked_query
                            case AgentType.FIXER.value:
                                result = FixerResponse.model_validate_json(response.content or "")
                                current_migration = result.fixed_query
                            case AgentType.SEMANTIC_VERIFIER.value:
                                logger.info("Semantic verifier agent response: %s", response.content)
                                result = SemanticVerifierResponse.model_validate_json(response.content or "")
                                if len(result.differences) > 0:
                                    description = {
                                        "role": AuthorRole.ASSISTANT.value,
                                        "name": AgentType.SEMANTIC_VERIFIER.value,
                                        "content": "\n".join(result.differences),
                                    }
                                    send_status_update(
                                        status=FileProcessUpdate(
                                            file.batch_id,
                                            file.file_id,
                                            ProcessStatus.COMPLETED,
                                            AgentType.SEMANTIC_VERIFIER,
                                            result.summary,
                                            FileResult.WARNING,
                                        ),
                                    )
                                    await batch_service.create_file_log(
                                        str(file.file_id),
                                        description,
                                        current_migration,
                                        LogType.WARNING,
                                        AgentType.SEMANTIC_VERIFIER,
                                        AuthorRole.ASSISTANT,
                                    )
                                elif response == "":
                                    send_status_update(
                                        status=FileProcessUpdate(
                                            file.batch_id,
                                            file.file_id,
                                            ProcessStatus.COMPLETED,
                                            AgentType.SEMANTIC_VERIFIER,
                                            "No return value from semantic verifier agent.",
                                            FileResult.WARNING,
                                        ),
                                    )
                                    await batch_service.create_file_log(
                                        str(file.file_id),
                                        "No return value from semantic verifier agent.",
                                        current_migration,
                                        LogType.WARNING,
                                        AgentType.SEMANTIC_VERIFIER,
                                        AuthorRole.ASSISTANT,
                                    )

                    except Exception as agent_error:
                        if is_content_safety_error(agent_error):
                            logger.warning(f"Content safety error from {response.name}: {str(agent_error)}")
                            await handle_content_safety_error(
                                agent_error, file, batch_service, current_migration, AgentType(response.name)
                            )
                            return ""
                        else:
                            raise agent_error

                description = {
                    "role": response.role,
                    "name": response.name or "*",
                    "content": response.content or "",
                }

                logger.info(description)

                try:
                    parsed_content = json.loads(response.content or "{}")
                    summary = parsed_content.get("summary", "")
                except json.JSONDecodeError:
                    logger.warning("Invalid JSON from agent: %s", response.content)
                    summary = "Response parsing error"

                send_status_update(
                    status=FileProcessUpdate(
                        file.batch_id,
                        file.file_id,
                        ProcessStatus.IN_PROGRESS,
                        AgentType(response.name),
                        summary,
                        FileResult.INFO,
                    ),
                )

                await batch_service.create_file_log(
                    str(file.file_id),
                    description,
                    current_migration,
                    LogType.INFO,
                    AgentType(response.name),
                    AuthorRole(response.role),
                )

        except (BadRequestError, HttpResponseError) as azure_error:
            if is_content_safety_error(azure_error):
                logger.warning(f"Azure content safety filter triggered: {str(azure_error)}")
                await handle_content_safety_error(azure_error, file, batch_service, current_migration)
                return ""
            else:
                raise azure_error

        except Exception as e:
            if is_content_safety_error(e):
                logger.warning(f"Content safety filter triggered: {str(e)}")
                await handle_content_safety_error(e, file, batch_service, current_migration)
                return ""
            else:
                logger.error("Error during chat.invoke(): %s", str(e))
                send_status_update(
                    status=FileProcessUpdate(
                        file.batch_id,
                        file.file_id,
                        ProcessStatus.COMPLETED,
                        AgentType.ALL,
                        f"Processing failed: {str(e)}",
                        FileResult.ERROR,
                    ),
                )
                break

        if chat.is_complete:
            is_complete = True

        break

    migrated_query = current_migration

    is_valid = await validate_migration(migrated_query, carry_response, file, batch_service)

    if not is_valid:
        logger.info("# Migration failed.")
        return ""

    logger.info("# Migration complete.")
    logger.info("Final query: %s\n", migrated_query)
    logger.info("Analysis of source and migrated queries:\n%s", "semantic verifier response")

    return migrated_query


async def validate_migration(
    migrated_query: str,
    carry_response: ChatMessageContent,
    file: FileRecord,
    batch_service: BatchService,
) -> bool:
    """Make sure the migrated query was returned"""
    if not migrated_query or migrated_query == "No migration":
        send_status_update(
            status=FileProcessUpdate(
                file.batch_id,
                file.file_id,
                ProcessStatus.COMPLETED,
                file_result=FileResult.ERROR,
            ),
        )
        
        # Apply harmful content prefix to the error message
        error_message = "No migrated query returned. Migration failed."
        
        await batch_service.create_file_log(
            str(file.file_id),
            error_message,
            "",
            LogType.ERROR,
            (
                AgentType.SEMANTIC_VERIFIER
                if carry_response is None
                else AgentType(carry_response.name)
            ),
            (
                AuthorRole.ASSISTANT
                if carry_response is None
                else AuthorRole(carry_response.role)
            ),
        )
        logger.error(error_message)
        return False

    send_status_update(
        status=FileProcessUpdate(
            batch_id=file.batch_id,
            file_id=file.file_id,
            process_status=ProcessStatus.COMPLETED,
            agent_type=AgentType.ALL,
            file_result=FileResult.SUCCESS,
        ),
    )
    await batch_service.create_file_log(
        file_id=str(file.file_id),
        description="Migration completed successfully.",
        last_candidate=migrated_query,
        log_type=LogType.SUCCESS,
        agent_type=AgentType.ALL,
        author_role=AuthorRole.ASSISTANT,
    )

    return True
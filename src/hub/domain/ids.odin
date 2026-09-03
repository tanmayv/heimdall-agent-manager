package domain

User_ID :: distinct string
Bridge_ID :: distinct string
Agent_ID :: distinct string
Agent_Instance_ID :: distinct string
Project_ID :: distinct string
Task_Chain_ID :: distinct string
Task_ID :: distinct string
Memory_ID :: distinct string
Chat_Conversation_ID :: distinct string
Chat_Message_ID :: distinct string
Artifact_ID :: distinct string
Template_ID :: distinct string

id_is_empty :: proc(id: string) -> bool {
	return id == ""
}
Scheduled_Prompt_ID :: distinct string

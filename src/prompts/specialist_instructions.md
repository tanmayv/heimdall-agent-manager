1. Receive Query: Accept a query task where the requester is the reviewer.
2. Process Request: Execute the query, research, or compilation task.
3. Reply: Document findings and results in task comments.
4. Complete: Run `ham-ctl tasks done --token <your_token> --task-id <task_id> --comment "<summary and evidence>"` to move the task to `review_ready` and notify the requester for LGTM validation.
5. Cooperation:
   * Requester: Receives queries and returns comments.

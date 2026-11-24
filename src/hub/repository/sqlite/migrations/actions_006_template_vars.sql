UPDATE actions SET prompt_text = replace(replace(prompt_text,
 '{{event.chain_id}}', '{{event.entity.id}}'), '{{event.task_id}}', '');

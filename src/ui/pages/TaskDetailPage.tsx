import React from 'react';
import { VaultText } from '../components/vault/VaultText';
import { TaskCommentsThread } from '../components/taskchain/TaskCommentsThread';

export interface TaskDetailPageProps {
  task: {
    taskId?: string;
    task_id?: string;
    title?: string;
    description?: string;
    [key: string]: any;
  };
  chainId: string;
}

export const TaskDetailPage: React.FC<TaskDetailPageProps> = ({ task, chainId }) => {
  const taskId = String(task.taskId || task.task_id || '');
  return (
    <div data-debug-id={`task-detail-page-${taskId}`} className="p-4 space-y-4">
      <h1 data-debug-id={`task-detail-title-${taskId}`} className="text-xl font-bold text-primary">
        <VaultText value={task.title} as="span" />
      </h1>
      <div data-debug-id={`task-detail-description-${taskId}`} className="text-sm text-secondary">
        <VaultText value={task.description} as="div" />
      </div>
      <div className="mt-4">
        <TaskCommentsThread chainId={chainId} taskId={taskId} enabled={true} />
      </div>
    </div>
  );
};

export default TaskDetailPage;

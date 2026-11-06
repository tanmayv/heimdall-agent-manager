export interface SubmissionSearchTarget {
  chain_id: string; task_id?: string; kind?: string; attempt?: string;
}
/** Historical output always opens its immutable attempt, never current runtime. */
export function ownerSubmissionRoute(hit: SubmissionSearchTarget): string | undefined {
  if (hit.kind !== 'output' || !hit.task_id || !/^[1-9][0-9]{0,18}$/.test(hit.attempt ?? '') || BigInt(hit.attempt!) > 9223372036854775807n) return undefined;
  return '/chains/' + encodeURIComponent(hit.chain_id) + '/tasks/' + encodeURIComponent(hit.task_id) + '/submissions/' + hit.attempt;
}
export function parseChainRoute(path: string): { chainId: string; taskId?: string; submissionAttempt?: string } {
  const rest = path.slice('/chains/'.length);
  const tasksAt = rest.indexOf('/tasks/');
  if (tasksAt < 0) return { chainId: decodeURIComponent(rest) };
  const task = rest.slice(tasksAt + '/tasks/'.length);
  const submissionsAt = task.indexOf('/submissions/');
  return {
    chainId: decodeURIComponent(rest.slice(0, tasksAt)),
    taskId: decodeURIComponent(submissionsAt < 0 ? task : task.slice(0, submissionsAt)),
    // Preserve an invalid explicit attempt so the strict read rejects it instead
    // of silently opening current task content.
    ...(submissionsAt < 0 ? {} : { submissionAttempt: decodeURIComponent(task.slice(submissionsAt + '/submissions/'.length)) }),
  };
}

import { COMMAND_TIMEOUT } from '../constants';
import { withTimeout } from './withTimeout';
import {
  READONLY_REFUSED,
  resolveReadonlyCommand,
  shouldRefuseCommand,
} from '../prokop/services/readonlyCommandGuard';

interface ExecuteShellCommandParams {
  command: string;
  args: string[];
  timeout?: number;
  // A read polled again and again (get_ui_state): while one run is still
  // going, even after its caller gave up waiting, a new call waits for that
  // run instead of starting another, so slow answers never pile up runs on
  // the router (FE-8).
  shared?: boolean;
}

interface ExecuteShellCommandResponse {
  stdout: string;
  stderr: string;
  code?: number;
}

export async function executeShellCommand({
  command: requestedCommand,
  args,
  timeout = COMMAND_TIMEOUT,
  shared = false,
}: ExecuteShellCommandParams): Promise<ExecuteShellCommandResponse> {
  const command = resolveReadonlyCommand(requestedCommand);

  if (shouldRefuseCommand(command, args)) {
    return { stdout: '', stderr: READONLY_REFUSED, code: 126 };
  }

  try {
    return await withTimeout(
      startExec(command, args, shared),
      timeout,
      [command, ...args].join(' '),
    );
  } catch (err) {
    const error = err as Error & { code?: unknown };
    const code = typeof error?.code === 'number' ? error.code : 1;

    return { stdout: '', stderr: error?.message, code };
  }
}

// Below the read-only check above, which runs before any exec.
const sharedRuns = new Map<string, Promise<ExecuteShellCommandResponse>>();

function startExec(command: string, args: string[], shared: boolean) {
  if (!shared) return fs.exec(command, args);
  const key = JSON.stringify([command, ...args]);
  let run = sharedRuns.get(key);
  if (!run) {
    run = Promise.resolve(fs.exec(command, args));
    const started = run;
    sharedRuns.set(key, started);
    const forget = () => {
      if (sharedRuns.get(key) === started) sharedRuns.delete(key);
    };
    started.then(forget, forget);
  }
  return run;
}

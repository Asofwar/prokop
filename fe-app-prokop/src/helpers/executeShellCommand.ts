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
}: ExecuteShellCommandParams): Promise<ExecuteShellCommandResponse> {
  const command = resolveReadonlyCommand(requestedCommand);

  if (shouldRefuseCommand(command, args)) {
    return { stdout: '', stderr: READONLY_REFUSED, code: 126 };
  }

  try {
    return await withTimeout(
      fs.exec(command, args),
      timeout,
      [command, ...args].join(' '),
    );
  } catch (err) {
    const error = err as Error & { code?: unknown };
    const code = typeof error?.code === 'number' ? error.code : 1;

    return { stdout: '', stderr: error?.message, code };
  }
}

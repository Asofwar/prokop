import { executeShellCommand } from '../../../helpers';
import { Prokop } from '../../types';

interface CallBaseMethodOptions {
  allowNonZeroWithStdout?: boolean;
  timeout?: number;
  shared?: boolean;
}

export async function callBaseMethod<T>(
  method: Prokop.AvailableMethods,
  args: string[] = [],
  command: string = '/usr/bin/prokop',
  options: CallBaseMethodOptions = {},
): Promise<Prokop.MethodResponse<T>> {
  try {
    const response = await executeShellCommand({
      command,
      args: [method as string, ...args],
      timeout: options.timeout ?? 15000,
      ...(options.shared ? { shared: true } : {}),
    });
    const exitCode = response.code ?? 0;

    if (
      exitCode !== 0 &&
      !(options.allowNonZeroWithStdout && response.stdout)
    ) {
      return {
        success: false,
        error: response.stderr || response.stdout || '',
      };
    }

    if (response.stdout) {
      try {
        return {
          success: true,
          data: JSON.parse(response.stdout) as T,
        };
      } catch (_e) {
        return {
          success: true,
          data: response.stdout as T,
        };
      }
    }

    return {
      success: false,
      error: response.stderr || '',
    };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : '',
    };
  }
}

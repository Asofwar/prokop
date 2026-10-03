import { ProkopShellMethods } from '../shell';

export function parseClashControllerHosts(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter(
        (host): host is string => typeof host === 'string' && host !== '',
      )
    : [];
}

// Router addresses of the Clash API controller, as the backend reads them
// from the running configuration (UC-125). Empty when unknown, which keeps
// the pages on rpcd.
export async function getClashControllerHosts(): Promise<string[]> {
  const response = await ProkopShellMethods.getDashboardRuntimeMetadata();

  return response.success
    ? parseClashControllerHosts(response.data.clashControllerHosts)
    : [];
}

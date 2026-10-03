type ToastType = 'success' | 'error' | 'warning' | 'info';

const DEFAULT_DURATION_MS = 3000;
// Errors stay long enough to be read (UC-143).
const ERROR_DURATION_MS = 8000;

export function showToast(
  message: string,
  type: ToastType,
  duration: number = type === 'error' ? ERROR_DURATION_MS : DEFAULT_DURATION_MS,
) {
  let container = document.querySelector('.toast-container');
  if (!container) {
    container = document.createElement('div');
    container.className = 'toast-container';
    // A live region, so screen readers announce every toast (UC-143).
    container.setAttribute('role', 'status');
    container.setAttribute('aria-live', 'polite');
    document.body.appendChild(container);
  }

  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;
  if (type === 'error') {
    // Errors interrupt the reader instead of waiting their turn.
    toast.setAttribute('role', 'alert');
  }
  toast.textContent = message;

  container.appendChild(toast);
  setTimeout(() => toast.classList.add('visible'), 100);

  setTimeout(() => {
    toast.classList.remove('visible');
    setTimeout(() => toast.remove(), 300);
  }, duration);
}

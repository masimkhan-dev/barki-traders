import { useCallback, useRef, KeyboardEvent } from 'react';

/**
 * Hook for keyboard-first form navigation
 * Enter moves to next field, only submits when on submit button
 */
export function useKeyboardNav() {
  const formRef = useRef<HTMLFormElement>(null);
  
  const handleKeyDown = useCallback((e: KeyboardEvent<HTMLFormElement>) => {
    if (e.key !== 'Enter') return;
    
    const target = e.target as HTMLElement;
    const tagName = target.tagName.toLowerCase();
    
    // Allow Enter to work normally on textareas
    if (tagName === 'textarea') return;
    
    // If on a submit button, let it submit
    if (tagName === 'button' && (target as HTMLButtonElement).type === 'submit') {
      return;
    }
    
    // Prevent form submission
    e.preventDefault();
    
    // Find all focusable elements in the form
    const form = formRef.current;
    if (!form) return;
    
    const focusableElements = Array.from(
      form.querySelectorAll<HTMLElement>(
        'input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), button:not([disabled])'
      )
    ).filter(el => {
      // Filter out elements in closed dialogs or hidden
      const rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    });
    
    const currentIndex = focusableElements.indexOf(target);
    
    if (currentIndex >= 0 && currentIndex < focusableElements.length - 1) {
      focusableElements[currentIndex + 1].focus();
    }
  }, []);
  
  return { formRef, handleKeyDown };
}

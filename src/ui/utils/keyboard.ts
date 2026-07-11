import React from 'react';

/**
 * Intercepts keydown events in text boxes and implements terminal-style Ctrl+W
 * (delete word backward) functionality.
 */
export function handleKeyDownCtrlW(e: React.KeyboardEvent<HTMLTextAreaElement | HTMLInputElement>) {
  if (e.key === 'w' && e.ctrlKey) {
    e.preventDefault(); // Prevent closing the tab/window or default browser behavior

    const target = e.currentTarget;
    const value = target.value;
    const start = target.selectionStart ?? 0;
    const end = target.selectionEnd ?? 0;

    if (start !== end) {
      // If there is an active selection, just delete the selection
      const newValue = value.substring(0, start) + value.substring(end);
      updateInputValue(target, newValue, start);
      return;
    }

    // Find the word boundary before the cursor
    let i = start - 1;

    // 1. Skip any trailing whitespace/punctuation directly before the cursor
    while (i >= 0 && /\s/.test(value[i])) {
      i--;
    }

    // 2. Skip the non-whitespace characters of the word
    while (i >= 0 && !/\s/.test(value[i])) {
      i--;
    }

    // i + 1 is the start of the word we want to delete.
    const deleteStart = i + 1;
    const newValue = value.substring(0, deleteStart) + value.substring(start);

    updateInputValue(target, newValue, deleteStart);
  }
}

function updateInputValue(target: HTMLTextAreaElement | HTMLInputElement, newValue: string, newCursorPos: number) {
  // Directly set value and dispatch synthetic 'input' event to trigger React's onChange state update
  target.value = newValue;
  const event = new Event('input', { bubbles: true });
  target.dispatchEvent(event);

  // Restore cursor position in the next tick after DOM update
  setTimeout(() => {
    target.setSelectionRange(newCursorPos, newCursorPos);
  }, 0);
}

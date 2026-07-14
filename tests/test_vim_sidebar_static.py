#!/usr/bin/env python3
"""Static regression checks for the Vim sidebar editor surface."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
VIM = (ROOT / 'src/ui/components/VimSidebar.tsx').read_text(encoding='utf-8')
CSS = (ROOT / 'src/ui/styles.css').read_text(encoding='utf-8')


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAILED: {msg}')
        sys.exit(1)


require("max-w-[45.6rem]" in VIM and "lg:max-w-[55.2rem]" in VIM, 'sidebar width should be increased by 20 percent')
require('function HeimdallVim' in VIM and "useVim({" in VIM, 'sidebar should use local Vimee wrapper')
require('keybinds: INSERT_ARROW_KEYBINDS' in VIM, 'local wrapper should install insert-mode arrow keybinds')
for key in ['<C-h>', '<C-l>', '<C-k>', '<C-j>']:
    require(f"keys: '{key}'" in VIM, f'insert mode keybind {key} missing')
for arrow in ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown']:
    require(arrow in VIM, f'{arrow} remap missing')
require('moveCursorForArrow' in VIM and "direction: ArrowDirection" in VIM, 'arrow movement helper missing')
require("'--cursor-top'" in VIM and "'--cursor-left'" in VIM, 'custom wrapped cursor positioning missing')
require('measureEditorWrapColumns' in VIM and 'ResizeObserver' in VIM, 'editor should measure available wrapping width')
require('white-space: pre-wrap;' in CSS, 'Vimee lines should wrap')
require('overflow-wrap: anywhere;' in CSS, 'long Vimee text should wrap instead of escaping view')
require('overflow-x: hidden;' in CSS and 'max-width: 100%;' in CSS, 'Vimee code area should stay within sidebar width')
require('top: var(--cursor-top' in CSS and 'left: var(--cursor-left' in CSS, 'CSS should honor wrapped cursor coordinates')

print('VIM SIDEBAR STATIC TEST PASSED')

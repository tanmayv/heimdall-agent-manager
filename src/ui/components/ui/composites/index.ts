/**
 * Composites barrel — assembled from primitives, still product-agnostic.
 * Re-exported through the top-level `@ui` barrel (`../index.ts`).
 */

export { PageShell } from './PageShell';
export type { PageShellProps, PageShellWidth } from './PageShell';

export { SectionHeader } from './SectionHeader';
export type { SectionHeaderProps } from './SectionHeader';

export { Panel } from './Panel';
export type { PanelProps, PanelPadding, PanelTone } from './Panel';

export { FormField } from './FormField';
export type { FormFieldProps } from './FormField';

export { Modal, ModalBody, ModalFooter } from './Modal';
export type { ModalProps, ModalSize } from './Modal';

export { Drawer } from './Drawer';
export type { DrawerProps, DrawerSize, DrawerSide } from './Drawer';

export { Menu, MenuItem } from './Menu';
export type { MenuProps, MenuItemProps } from './Menu';

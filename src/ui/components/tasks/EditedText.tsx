// An edited line with its inserted span marked (origin/main kept this in
// RequirementsEditorModal, which this branch does not carry).

import { containsVaultArmored } from '../../utils/vaultCrypto';
import { VaultText } from '../vault';
import { inlineChange } from './ticketModel';

export function EditedText({ previous, text }: { previous?: string; text: string }) {
  if (!previous || containsVaultArmored(previous) || containsVaultArmored(text)) return <VaultText value={text} />;
  const { prefix, changed, suffix } = inlineChange(previous, text);
  return (
    <>
      {prefix}
      {changed && <mark className="rounded-sm bg-success-soft px-0.5 text-primary">{changed}</mark>}
      {suffix}
    </>
  );
}

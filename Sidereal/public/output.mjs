// Only remove a recognized, idle Grok composer at the end of a snapshot.
// Unknown prompts, approvals, and Mac-side drafts stay visible. Raw mode is lossless.
export function readableOutput(snapshot) {
  const lines = snapshot.split('\n');
  for (let index = lines.length - 1; index >= 0; index--) {
    if (!/^\s*[─━]{8,}\s*$/.test(lines[index])) continue;
    const footer = lines.slice(index + 1).join(' ').replace(/\s+/g, ' ').trim();
    if (/^[│|]? ?[❯›>] ?(?:Build anything )?Grok [\w.-]+ \([\w-]+\) · [\w-]+ →:expand [│|] Ctrl\+e:collapse thinking [│|] Ctrl\+x:shortcuts ?[│|]?$/.test(footer)) {
      lines.splice(index);
      break;
    }
  }
  while (lines.length && !lines[0].trim()) lines.shift();
  while (lines.length && !lines.at(-1).trim()) lines.pop();
  const output = lines.join('\n');
  // Empty terminal borders are not conversation content.
  return /^[\s┌┐└┘│─]*$/.test(output) ? '' : output;
}

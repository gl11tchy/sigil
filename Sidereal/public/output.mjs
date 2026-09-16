// Only remove a recognized, idle Grok composer at the end of a snapshot.
// Unknown prompts, approvals, and Mac-side drafts stay visible. Raw mode is lossless.

const RULE = /^\s*[─━]{8,}\s*$/;
const PADDING = /^[\s┌┐└┘│╭╮╯╰▀▄█▌▐░▒▓]+$/;
const GROK_META = /\bGrok [\w.-]+ \([\w-]+\) · [\w-]+\b/;
const SHORTCUTS = /Ctrl\+x:shortcuts/;
const HINT = /(?:Build anything|Shift\+Tab:mode|→:expand|Ctrl\+e:collapse thinking|Esc:cancel)/;
const EMPTY_PROMPT = /^[│| ]*[❯›>] ?(?:Build anything)?\s*$/;
const GROK_NAME = /^Grok [\w.-]+$/;
const GROK_MODEL = /^\([\w-]+\) · [\w-]+$/;

function tidy(line) {
  return line.trimEnd();
}

function isPadding(line) {
  return !line.trim() || PADDING.test(line);
}

function isChromeLine(line) {
  const text = line.replace(/[│|]/g, '').trim();
  if (!text) return true;
  if (RULE.test(line) || isPadding(line)) return true;
  if (GROK_META.test(text) || SHORTCUTS.test(text) || HINT.test(text)) return true;
  if (GROK_NAME.test(text) || GROK_MODEL.test(text)) return true;
  if (EMPTY_PROMPT.test(line) || EMPTY_PROMPT.test(text)) return true;
  return false;
}

function isIdleComposer(footerLines) {
  const footer = footerLines.join(' ').replace(/\s+/g, ' ').trim();
  if (!SHORTCUTS.test(footer) || !GROK_META.test(footer)) return false;
  return footerLines.every(isChromeLine);
}

export function readableOutput(snapshot) {
  const lines = snapshot.split('\n').map(tidy);
  for (let index = lines.length - 1; index >= 0; index--) {
    if (!RULE.test(lines[index])) continue;
    if (!isIdleComposer(lines.slice(index + 1))) continue;
    lines.splice(index);
    while (lines.length && RULE.test(lines.at(-1))) lines.pop();
    break;
  }
  while (lines.length && isPadding(lines[0])) lines.shift();
  while (lines.length && isPadding(lines.at(-1))) lines.pop();
  const compact = [];
  let blanks = 0;
  for (const line of lines) {
    if (isPadding(line)) {
      if (++blanks === 1) compact.push('');
    } else {
      blanks = 0;
      compact.push(line);
    }
  }
  const output = compact.join('\n').trim();
  return /^[\s┌┐└┘│─━]*$/.test(output) ? '' : output;
}

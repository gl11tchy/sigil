// Only remove a recognized, idle Grok composer at the end of a snapshot.
// Unknown prompts, approvals, and Mac-side drafts stay visible. Raw mode is lossless.

const BOX = /[\s┌┐└┘│─━├┤┬┴┼╭╮╯╰▀▄█▌▐░▒▓|]/g;
const BOX_LINE = /^[\s┌┐└┘│─━├┤┬┴┼╭╮╯╰▀▄█▌▐░▒▓]+$/;
const PADDING = /^[\s┌┐└┘│╭╮╯╰▀▄█▌▐░▒▓]+$/;
const GROK_META = /Grok [\w.-]+ \([^)]+\) · \S+/;
const SHORTCUTS = /Ctrl\+x:shortcuts/;
const HINT_TOKEN = /Ctrl\+x:shortcuts|Shift\+Tab:mode|Esc:cancel|Ctrl\+e:collapse thinking|→:expand|Build anything|↩/g;
const EMPTY_PROMPT = /^[│| ]*[❯›>] ?(?:Build anything)?\s*$/;
const GROK_NAME = /^Grok [\w.-]+$/;
const GROK_MODEL = /^\(?[\w-]+\)? · [\w-]+/;

function tidy(line) {
  return line.trimEnd();
}

function isPadding(line) {
  return !line.trim() || PADDING.test(line);
}

function isBoxLine(line) {
  return Boolean(line.trim()) && BOX_LINE.test(line);
}

function ink(line) {
  return line.replace(BOX, ' ').replace(/\s+/g, ' ').trim();
}

function isHintRow(text) {
  if (!text) return false;
  const rest = text.replace(HINT_TOKEN, '').replace(/[|·]/g, ' ').replace(/\s+/g, ' ').trim();
  return rest.length === 0 && (SHORTCUTS.test(text) || /Shift\+Tab:mode|→:expand|Build anything/.test(text));
}

function isComposerChrome(line) {
  if (!line.trim() || isBoxLine(line) || isPadding(line)) return true;
  const text = ink(line);
  if (!text) return true;
  if (EMPTY_PROMPT.test(line) || EMPTY_PROMPT.test(text)) return true;
  if (GROK_META.test(text) || GROK_NAME.test(text) || GROK_MODEL.test(text)) return true;
  if (isHintRow(text) || isHintRow(line.trim())) return true;
  if (/^always-?approve$/i.test(text)) return true;
  if (/Build anything/.test(text)) {
    const rest = text.replace(/Build anything/g, '').replace(/Grok [\w.-]+/g, '').replace(/[❯›>]/g, '').trim();
    if (!rest) return true;
  }
  return false;
}

function isDraftPrompt(line) {
  const text = ink(line);
  if (!text || EMPTY_PROMPT.test(line) || EMPTY_PROMPT.test(text)) return false;
  return /^[❯›>] \S/.test(text);
}

function isTreeOnly(line) {
  return /^[│| \t]+$/.test(line);
}

function isTurnChrome(line) {
  const whole = line.trim();
  if (!whole) return false;
  if (/\[hooks:\s*\d+\/\d+\]/.test(whole)) return true;
  if (/^(?:[♦◆∴:]\s*)?(?:Thought for \d|Thinking\.{3}|Waiting for response|Worked for \d)/i.test(whole)) return true;
  if (/^\d+[hms]?[\d.]*s?\s*↓/.test(whole)) return true;
  if (/^\d{1,2}:\d{2} [AP]M$/.test(whole)) return true;
  if (/^∴\s/.test(whole)) return true;
  return false;
}

function stripClock(line) {
  return line.replace(/\s{2,}\d{1,2}:\d{2} [AP]M\s*$/, '');
}

function unindentBubble(line) {
  const match = line.match(/^(\s{4,})([A-Z].*)/);
  if (!match || match[2].trim().split(/\s+/).length < 4) return line;
  return match[2];
}

function isProseWrap(previous, line) {
  if (!previous || !line) return false;
  const prev = previous.trim();
  const next = line.trim();
  if (!prev || !next) return false;
  if (/[.!?:;{}]$/.test(prev)) return false;
  if (/^\s{1,4}\S/.test(line) && !/^\s{6,}/.test(line)) return false;
  return /^[a-z0-9]/.test(next);
}

function stripTreeGutter(line) {
  const trimmed = line.trimEnd();
  if (/[│|]$/.test(trimmed) && /^[│|]/.test(trimmed.trimStart())) return line;
  return line.replace(/^(?:[ \t]*[│|])+[ \t]{2,}/, '');
}

function trailingComposerStart(lines) {
  let index = lines.length - 1;
  while (index >= 0 && isComposerChrome(lines[index])) index--;
  const start = index + 1;
  if (start >= lines.length) return -1;
  const slice = lines.slice(start);
  const block = slice.join(' ');
  if (!SHORTCUTS.test(block)) return -1;
  if (!GROK_META.test(block) && !/Grok [\w.-]+/.test(block) && !/Shift\+Tab:mode|→:expand/.test(block)) {
    return -1;
  }
  if (index >= 0 && isDraftPrompt(lines[index])) return -1;
  const hasPrompt = slice.some(line => EMPTY_PROMPT.test(line) || EMPTY_PROMPT.test(ink(line)) || /Build anything/.test(line));
  const hasBox = slice.some(isBoxLine);
  if (!hasPrompt && !hasBox) return -1;
  return start;
}

export function readableOutput(snapshot) {
  const lines = snapshot.split('\n').map(tidy);
  const start = trailingComposerStart(lines);
  if (start >= 0) {
    lines.splice(start);
    while (lines.length && (isPadding(lines.at(-1)) || isBoxLine(lines.at(-1)))) lines.pop();
  }
  while (lines.length && isPadding(lines[0])) lines.shift();
  while (lines.length && isPadding(lines.at(-1))) lines.pop();
  const compact = [];
  let blanks = 0;
  for (const line of lines) {
    const cleaned = stripClock(stripTreeGutter(line));
    if (isPadding(cleaned) || isTreeOnly(cleaned) || isTurnChrome(cleaned)) {
      if (++blanks === 1) compact.push('');
    } else {
      blanks = 0;
      if (isProseWrap(compact.at(-1), cleaned)) {
        compact[compact.length - 1] = `${compact.at(-1).trim()} ${cleaned.trim()}`;
      } else {
        compact.push(unindentBubble(cleaned));
      }
    }
  }
  const output = compact.join('\n').trim();
  return /^[\s┌┐└┘│─━]*$/.test(output) ? '' : output;
}

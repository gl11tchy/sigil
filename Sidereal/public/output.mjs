// Only remove a recognized, idle Grok composer at the end of a snapshot.
// Unknown prompts, approvals, and Mac-side drafts stay visible. Raw mode is lossless.

const SPINNER = '\u2800-\u28FF\uFFFD●○◐◓◑◒■□▪▫◼◻';
const BOX = new RegExp(`[\\s┌┐└┘│─━├┤┬┴┼╭╮╯╰▀▄█▌▐░▒▓|${SPINNER}]`, 'g');
const BOX_LINE = new RegExp(`^[\\s┌┐└┘│─━├┤┬┴┼╭╮╯╰▀▄█▌▐░▒▓${SPINNER}]+$`);
const PADDING = new RegExp(`^[\\s┌┐└┘│╭╮╯╰▀▄█▌▐░▒▓${SPINNER}]+$`);
const TREE_ONLY = new RegExp(`^[│| \\t${SPINNER}]+$`);
const SPINNER_ONLY = new RegExp(`^[${SPINNER}]+$`, 'u');
const HAS_SPINNER = new RegExp(`[${SPINNER}]`, 'u');
const LEADING_SPINNER = new RegExp(`^[${SPINNER}]+(?=\\s*(?:[│|]|$))`, 'u');
const GROK_META = /Grok [\w.-]+ \([^)]+\) · \S+/;
const SHORTCUTS = /Ctrl\+x:(?:shortcuts)?/;
const HINT_TOKEN = /Ctrl\+x:(?:shortcuts)?|Shift\+Tab:mode|Esc:cancel|Ctrl\+e:collapse thinking|→:expand|Build anything|↩/g;
const EMPTY_PROMPT = /^[│| ]*[❯›>] ?(?:Build anything|- grok)?\s*$/i;
const GROK_NAME = /^Grok [\w.-]+$/;
const GROK_MODEL = /^\(?[\w-]+\)? · [\w-]+/;
const TURN_STATUS = /^(?:Run |stop\b|user_prompt_submit|Thought for \d|Thinking(?:\.{3}|…)|Waiting for response|Worked for \d)/i;
const SPINNER_PREFIX = new RegExp(`^[\\s${SPINNER}♦◆▼▽∴:|│]+`);
// Only a turn or spinner glyph marks peeled status text; pipes and bullets frame real content.
const TURN_GLYPH = /[\u2800-\u28FF\uFFFD◐◓◑◒♦◆▼▽]/;
const FOOTER_ARROW = /^\d+[hms]?[\d.]*s?\s*[↓⬇][\d.]+k\b/;

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

function peelSpinner(line) {
  return line.replace(SPINNER_PREFIX, '').trim();
}

function isSpinnerOnly(line) {
  const text = line.trim();
  return Boolean(text) && SPINNER_ONLY.test(text);
}

// Peel a leading braille/tofu spinner only when the rest is empty or a TUI
// gutter, so "⣿ GPU utilization" stays intact.
function peelLeadingSpinner(line) {
  return line.replace(LEADING_SPINNER, '');
}

function isSpinnerRow(original, cleaned) {
  if (isSpinnerOnly(cleaned) || isSpinnerOnly(original)) return true;
  return HAS_SPINNER.test(original) && isTreeOnly(cleaned);
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
  if (/Build anything/.test(text) || (/[❯›>]/.test(text) && /- grok/i.test(text))) {
    const rest = text.replace(/Build anything/gi, '').replace(/- grok/gi, '').replace(/Grok [\w.-]+/g, '').replace(/[❯›>]/g, '').trim();
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
  return TREE_ONLY.test(line);
}

function isTurnChrome(line, previous) {
  const whole = line.trim();
  if (!whole) return false;
  if (/\[hooks:\s*\d+(?:\/\d+)?\]/.test(whole)) return true;
  if (/^[▼▽]\s*task completed in \d/i.test(whole)) return true;
  if (/^[♦◆▼▽]\s+(?:Run |stop\b|user_prompt_submit|Thought for \d|Thinking(?:\.{3}|…)|Waiting for response|Worked for \d)/i.test(whole)) return true;
  if (/^(?:[♦◆∴:]\s*)?(?:Thought for \d|Thinking(?:\.{3}|…)|Waiting for response|Worked for \d)/i.test(whole)) return true;
  const peeled = peelSpinner(whole);
  if (peeled && peeled !== whole && TURN_GLYPH.test(whole.match(SPINNER_PREFIX)[0]) && TURN_STATUS.test(peeled)) return true;
  if (FOOTER_ARROW.test(whole) || FOOTER_ARROW.test(peeled)) return true;
  if (/^\d{1,2}:\d{2} [AP]M$/.test(whole) || /^\d{1,2}:\d{2} [AP]M$/.test(peeled)) return Boolean(previous);
  if (/^∴\s/.test(whole) || /^∴\s/.test(peeled)) return true;
  if (/^\[stop\]$/i.test(peeled)) return true;
  return false;
}

function stripClock(line) {
  return line.replace(/\s{2,}\d{1,2}:\d{2} [AP]M\s*$/, '');
}

function unindentBubble(line) {
  const match = line.match(/^(\s{6,})([A-Z].*)/);
  if (!match || match[2].trim().split(/\s+/).length < 4) return line;
  return match[2];
}

function isProseWrap(previous, line) {
  if (!previous || !line) return false;
  const prev = previous.trim();
  const next = line.trim();
  if (!prev || !next) return false;
  if (prev.split(/\s+/).length < 5) return false;
  if (/[.!?:;{}]$/.test(prev)) return false;
  if (/^\s{1,4}\S/.test(line) && !/^\s{6,}/.test(line)) return false;
  return /^[a-z0-9]/.test(next);
}

function unwrapTuiFrame(line) {
  const trimmed = line.trimEnd();
  const framed = /^[ \t]*[│|]/.test(trimmed) && /[│|]$/.test(trimmed);
  if (framed) {
    const inner = trimmed.replace(/^[ \t]*[│|]/, '').replace(/[│|]\s*$/, '');
    if (/[│|]/.test(inner)) return { line: trimmed, bubble: false };
    const words = inner.replace(/\s+/g, ' ').trim().split(' ').filter(Boolean);
    const continuation = /^[ \t]{2,}\S/.test(inner);
    const timed = /\d{1,2}:\d{2} [AP]M/.test(inner);
    const indented = /^[ \t]{2,}/.test(inner);
    if (!timed && !continuation && !indented && words.length < 4) return { line: trimmed, bubble: false };
    return { line: inner.trim(), bubble: true };
  }

  const box = trimmed.match(/^[ \t]*[│┃┆┊]([ \t]*)(.*)$/u);
  if (box && !/[│|]/.test(box[2])) {
    const spaces = box[1];
    const inner = box[2];
    const proseMark = /^(?:[•\-–—*…]|\.{2,}|[A-ZÀ-ÖØ-Þ])/.test(inner);
    if (spaces.length >= 2 || proseMark) {
      const words = inner.replace(/\s+/g, ' ').trim().split(' ').filter(Boolean);
      return { line: inner.trimStart(), bubble: words.length >= 3 || proseMark };
    }
  }

  const ascii = trimmed.match(/^[ \t]*\|([ \t]*)(.*)$/);
  if (ascii) {
    const spaces = ascii[1];
    const inner = ascii[2];
    const proseMark = /^(?:[•\-–—*…]|\.{2,}|[A-ZÀ-ÖØ-Þ])/.test(inner);
    if ((spaces.length >= 2 || (spaces.length >= 1 && proseMark)) && !/[│|]/.test(inner)) {
      const words = inner.replace(/\s+/g, ' ').trim().split(' ').filter(Boolean);
      return { line: inner.trimStart(), bubble: words.length >= 3 || proseMark };
    }
  }

  return { line: trimmed.replace(/^(?:[ \t]*[│|])+[ \t]{2,}/, ''), bubble: false };
}

function trailingComposerStart(lines) {
  let index = lines.length - 1;
  while (index >= 0 && isComposerChrome(lines[index])) index--;
  const start = index + 1;
  if (start >= lines.length) return -1;
  const slice = lines.slice(start);
  const block = slice.join(' ');
  // Phone-width terminals truncate "Ctrl+x:shortcuts" to "Ctrl+x:".
  if (!SHORTCUTS.test(block) && !/Shift\+Tab:mode/.test(block)) return -1;
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
  let inBubble = false;
  for (const line of lines) {
    const unwrapped = unwrapTuiFrame(peelLeadingSpinner(line));
    const cleaned = stripClock(unwrapped.line);
    const previous = compact.at(-1);
    if (isTurnChrome(cleaned, previous && previous !== '' ? previous : '')) {
      if (++blanks === 1) compact.push('');
      inBubble = false;
    } else if (isSpinnerRow(line, cleaned)) {
      // Ink draws the spinner on its own row, sometimes with an empty gutter.
      // That is not a paragraph break.
    } else if (isPadding(cleaned) || isTreeOnly(cleaned)) {
      if (++blanks === 1) compact.push('');
      inBubble = false;
    } else {
      blanks = 0;
      const bubble = unwrapped.bubble || /^\s{6,}/.test(line) || inBubble;
      if (inBubble && isProseWrap(previous, cleaned)) {
        compact[compact.length - 1] = `${previous.trim()} ${cleaned.trim()}`;
      } else {
        compact.push(unindentBubble(cleaned));
        inBubble = unwrapped.bubble || (bubble && /^[A-Z]/.test(cleaned.trim()));
      }
    }
  }
  while (compact.length && !compact[0].trim()) compact.shift();
  while (compact.length && !compact.at(-1).trim()) compact.pop();
  const output = compact.join('\n');
  return new RegExp(`^[\\s┌┐└┘│─━${SPINNER}]*$`).test(output) ? '' : output;
}

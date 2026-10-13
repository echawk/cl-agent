// copilot.js -- the editors' copilot (copilot.lisp), shared by the Code tab
// (the Lem view and the simple editor) and the Lisp tab: its settings, its
// toolbar controls, and the options that give a lisp-editor.js editor its
// suggestions.
//
//   copilotBox(onChange?)        "Copilot on/off" and the model, kept current
//                                wherever they are shown; ONCHANGE runs after
//                                a change (to give focus back to an editor)
//   copilotOptions(pathFn, {auto})  suggest/suggestAuto/suggestDelay options
//                                for createLispEditor: PATHFN names the file (and
//                                so the language) the text is from; AUTO false
//                                means only C-c Tab asks (the REPL)

import { el, api } from './core.js';

let settings = null;          // {auto, model, sessionModel, delayMs, models, ...}
let loading = null;

export function copilotSettings() { return settings || {}; }

export function loadCopilot() {
  loading = loading || (async () => {
    try {
      const [status, models] = await Promise.all([api('/api/copilot'), api('/api/models').catch(() => ({ models: [] }))]);
      settings = { ...status, models: models.models || [] };
    } catch (err) { settings = { error: err.message, models: [] }; }
    loading = null;
    render();
  })();
  return loading;
}

async function change(what, onChange) {
  try { settings = { ...settings, ...(await api('/api/copilot', { method: 'POST', body: what })) }; }
  catch (err) { settings = { ...settings, error: err.message }; }
  render();
  onChange?.();
}

function controls(onChange) {
  const c = settings || {};
  const session = c.sessionModel ? `session (${c.sessionModel})` : 'session model';
  const models = (c.models || []).filter(m => m !== c.sessionModel);
  if (c.model && !models.includes(c.model)) models.unshift(c.model);
  return [
    el('button', {
      class: `btn btn-small code-copilot ${c.auto ? 'on' : ''}`, type: 'button', 'aria-pressed': String(!!c.auto),
      'data-doc': c.auto
        ? 'The copilot is suggesting as you type (Tab takes a suggestion, M-Right its first line). Click to stop; C-c Tab still asks.'
        : 'Have the copilot suggest code as you type. Off, C-c Tab asks it anyway.',
      onclick: () => change({ auto: !c.auto }, onChange),
    }, c.auto ? 'Copilot on' : 'Copilot off'),
    el('select', {
      class: 'field code-copilot-model', 'aria-label': 'Copilot model',
      'data-doc': 'The model the copilot asks: its own requests, apart from the conversation',
      onchange: e => change({ model: e.target.value }, onChange),
    },
    el('option', { value: '', selected: !c.model }, session),
    ...models.map(m => el('option', { value: m, selected: m === c.model }, m))),
  ];
}

const boxes = new Map();      // box -> its onChange

function render() {
  for (const [box, onChange] of boxes) {
    if (!box.isConnected) boxes.delete(box);
    else box.replaceChildren(...controls(onChange));
  }
}

export function copilotBox(onChange) {
  if (!settings) loadCopilot();
  const box = el('span', { class: 'code-copilot-box' }, ...controls(onChange));
  boxes.set(box, onChange);
  return box;
}

export function copilotOptions(pathFn, { auto = true } = {}) {
  if (!settings) loadCopilot();
  return {
    suggest: async (text, cursor) => {
      const json = await api('/api/copilot/suggest', {
        method: 'POST', body: { path: pathFn(), before: text.slice(0, cursor), after: text.slice(cursor) },
      });
      return json.text || '';
    },
    suggestAuto: () => auto && !!settings?.auto,
    suggestDelay: () => settings?.delayMs || 700,
  };
}

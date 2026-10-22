// Run real event handlers against a small DOM stand-in; browser QA stays separate.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../dist/index.html', import.meta.url), 'utf8');
const script = fs.readFileSync(new URL('../dist/app.js', import.meta.url), 'utf8');
let focus = null;
let viewportWidth = 1200;
class Element {
  constructor(attributes = {}) {
    this.attributes = attributes;
    this.dataset = {};
    for (const [key, value] of Object.entries(attributes)) {
      if (key.startsWith('data-')) this.dataset[key.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
    }
    this.hidden = 'hidden' in attributes;
    this.listeners = {};
    this.values = {};
    this.style = { setProperty: (key, value) => { this.values[key] = value; } };
    this.classes = new Set((attributes.class ?? '').split(' '));
    this.classList = { toggle: (key, enabled) => enabled ? this.classes.add(key) : this.classes.delete(key) };
  }
  setAttribute(key, value) { this.attributes[key] = value; }
  addEventListener(key, handler) { (this.listeners[key] ??= []).push(handler); }
  emit(key, event = {}) { for (const handler of this.listeners[key] ?? []) handler({ target: this, preventDefault() {}, ...event }); }
  focus() { focus = this; }
  setPointerCapture() {}
  getBoundingClientRect() { return { width: viewportWidth }; }
}
const elements = [];
for (const match of html.matchAll(/<[a-z][^>]*>/g)) {
  const attrs = {};
  for (const attribute of match[0].matchAll(/([\w-]+)="([^"]*)"/g)) attrs[attribute[1]] = attribute[2];
  if (/\shidden(?:\s|>)/.test(match[0])) attrs.hidden = '';
  elements.push(new Element(attrs));
}
function queryAll(selector) {
  if (selector.startsWith('#')) return elements.filter(node => node.attributes.id === selector.slice(1));
  if (selector.startsWith('.')) return elements.filter(node => node.classes.has(selector.slice(1)));
  const attr = selector.match(/^\[([^=\]]+)(?:="([^"]+)")?\]$/);
  if (attr) return elements.filter(node => attr[1] in node.attributes && (!attr[2] || node.attributes[attr[1]] === attr[2]));
  throw new Error(`Unsupported query: ${selector}`);
}
const labelSpan = new Element();
const query = selector => selector === '.resource-label>span' ? labelSpan : (queryAll(selector)[0] ?? assert.fail(`Missing ${selector}`));
query('#cpu-value').nextElementSibling = new Element();
query('#ram-value').nextElementSibling = new Element();
const media = { matches: false, listeners: [], addEventListener(_key, fn) { this.listeners.push(fn); } };
const resize = [];
vm.runInNewContext(script, {
  document: { querySelector: query, querySelectorAll: queryAll, getElementById: id => query(`#${id}`) },
  window: { matchMedia: () => media, addEventListener: (_key, fn) => resize.push(fn) }
});
assert.equal(query('#server-title').textContent, 'aurora-lab');
assert.equal(query('#toggle-left').attributes['aria-expanded'], 'true');
query('#toggle-left').emit('click');
assert.equal(query('#server-pane').inert, true);
assert.equal(query('#app-body').values['--left-width'], '0px');
query('#toggle-left').emit('click');
assert.equal(query('#server-pane').inert, false);
const left = query('[data-drag="left"]');
left.emit('keydown', { key: 'End' });
assert.equal(query('#app-body').values['--left-width'], '260px');
left.emit('keydown', { key: 'Home' });
assert.equal(query('#server-pane').inert, true);
query('#toggle-left').emit('click');
left.emit('pointerdown', { button: 0, clientX: 260, pointerId: 1 });
left.emit('pointermove', { clientX: 10 });
left.emit('pointerup');
assert.equal(query('#server-pane').inert, true);
query('#toggle-right').emit('click');
assert.equal(query('#resource-pane').inert, true);
query('#settings-toggle').emit('click');
assert.equal(query('#demo-settings').hidden, false);
query('[data-theme-choice="dark"]').emit('click');
assert.equal(query('#demo').dataset.theme, 'dark');
assert.equal(query('[data-theme-choice="light"]').attributes['aria-pressed'], 'false');
query('#font-size').emit('input', { target: { value: '16' } });
assert.equal(query('#demo').values['--terminal-font'], '16px');
query('#demo').emit('keydown', { key: 'Escape' });
assert.equal(query('#demo-settings').hidden, true);
assert.equal(focus, query('#settings-toggle'));
query('[data-server="local"]').emit('click');
assert.equal(query('#server-title').textContent, '이 Mac');
assert.equal(query('#net-value').innerHTML, '—');
assert.equal(query('.gpu-grid').hidden, true);
assert.equal(query('.gpu-unavailable').hidden, false);
query('[data-server="willow"]').emit('click');
assert.equal(query('#server-title').textContent, 'willow-dev');
assert.equal(query('.gpu-grid').hidden, false);
query('[data-tab="training"]').emit('keydown', { key: 'ArrowRight' });
assert.equal(query('[data-tab="monitor"]').attributes['aria-selected'], 'true');
assert.equal(focus, query('[data-tab="monitor"]'));
assert.match(query('#terminal-output').innerHTML, /tmux list-sessions/);
query('[data-server="harbor"]').emit('click');
assert.match(query('#terminal-output').innerHTML, /session not connected/);
query('[data-server="cedar"]').emit('click');
assert.equal(query('#server-title').textContent, 'cedar-test');
assert.match(query('#terminal-output').innerHTML, /session not connected/);
viewportWidth = 375;
media.matches = true;
media.listeners.forEach(listener => listener());
query('[data-mobile-choice="resources"]').emit('click');
assert.equal(query('#resource-pane').inert, false);
assert.equal(query('.terminal-pane').inert, true);
assert.equal(query('#demo').dataset.mobilePanel, 'resources');
query('[data-mobile-choice="servers"]').emit('click');
assert.equal(query('#server-pane').inert, false);
query('[data-server="aurora"]').emit('click');
assert.equal(query('#demo').dataset.mobilePanel, 'terminal');
assert.equal(query('.terminal-pane').inert, false);
assert.equal(query('#server-pane').inert, true);
assert.equal(focus, query('#terminal-output'));
console.log('PASS: desktop pane toggles; keyboard/pointer resize; settings; theme/font; 5 server modes; tabs; mobile panel/focus state');

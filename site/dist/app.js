'use strict';

(() => {
  const demo = document.querySelector('#demo');
  const body = document.querySelector('#app-body');
  const mobile = window.matchMedia('(max-width: 850px)');
  const settings = document.querySelector('#demo-settings');
  const settingsToggle = document.querySelector('#settings-toggle');
  const serverButtons = [...document.querySelectorAll('[data-server]')];
  const tabs = [...document.querySelectorAll('[data-tab]')];
  const mobileButtons = [...document.querySelectorAll('[data-mobile-choice]')];
  const state = {
    left: { open: true, width: 190, minimum: 150, maximum: 260 },
    right: { open: true, width: 250, minimum: 200, maximum: 340 },
    server: 'aurora', tab: 'training', mobilePanel: 'terminal'
  };
  const servers = {
    local: { name: '이 Mac', account: 'local', cpu: 12, ram: 41, net: '—', local: true },
    aurora: { name: 'aurora-lab', account: 'research', cpu: 28, ram: 64, net: '12.4' },
    willow: { name: 'willow-dev', account: 'developer', cpu: 16, ram: 38, net: '3.2' },
    harbor: { name: 'harbor-store', account: 'ops', cpu: 9, ram: 22, net: '5.6', idle: true },
    cedar: { name: 'cedar-test', account: 'tester', cpu: 4, ram: 18, net: '0.8', idle: true }
  };

  function renderPanels() {
    const available = body.getBoundingClientRect().width;
    const budget = Math.max(0, available - 28 - 245);
    const desired = (state.left.open ? state.left.width : 0) + (state.right.open ? state.right.width : 0);
    const scale = desired > budget ? budget / desired : 1;
    for (const [edge, id] of [['left', 'server-pane'], ['right', 'resource-pane']]) {
      const pane = document.getElementById(id);
      const value = state[edge].open ? Math.round(state[edge].width * scale) : 0;
      body.style.setProperty(`--${edge}-width`, `${value}px`);
      const button = document.querySelector(`#toggle-${edge}`);
      const name = edge === 'left' ? '서버 목록' : '자원 패널';
      button.setAttribute('aria-expanded', String(state[edge].open));
      button.setAttribute('aria-label', `${name} ${state[edge].open ? '접기' : '펼치기'}`);
      button.textContent = (edge === 'left') === state[edge].open ? '‹' : '›';
      const visible = mobile.matches ? state.mobilePanel === (edge === 'left' ? 'servers' : 'resources') : state[edge].open;
      pane.inert = !visible;
      pane.setAttribute('aria-hidden', String(!visible));
      document.querySelector(`[data-drag="${edge}"]`).setAttribute('aria-valuenow', String(value));
    }
    const terminalVisible = !mobile.matches || state.mobilePanel === 'terminal';
    document.querySelector('.terminal-pane').inert = !terminalVisible;
    document.querySelector('.terminal-pane').setAttribute('aria-hidden', String(!terminalVisible));
    demo.dataset.mobilePanel = state.mobilePanel;
    mobileButtons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.mobileChoice === state.mobilePanel)));
  }

  for (const edge of ['left', 'right']) {
    document.querySelector(`#toggle-${edge}`).addEventListener('click', () => {
      state[edge].open = !state[edge].open;
      renderPanels();
    });
    const handle = document.querySelector(`[data-drag="${edge}"]`);
    let drag = null;
    function setWidth(proposed) {
      const pane = state[edge];
      pane.open = proposed >= pane.minimum / 2;
      if (pane.open) pane.width = Math.min(pane.maximum, Math.max(pane.minimum, proposed));
      renderPanels();
    }
    handle.addEventListener('pointerdown', event => {
      if (event.button !== 0) return;
      drag = { x: event.clientX, width: state[edge].open ? state[edge].width : 0 };
      handle.setPointerCapture(event.pointerId);
      event.preventDefault();
    });
    handle.addEventListener('pointermove', event => {
      if (!drag) return;
      setWidth(drag.width + (event.clientX - drag.x) * (edge === 'left' ? 1 : -1));
    });
    const endDrag = () => { drag = null; };
    handle.addEventListener('pointerup', endDrag);
    handle.addEventListener('pointercancel', endDrag);
    handle.addEventListener('lostpointercapture', endDrag);
    handle.addEventListener('keydown', event => {
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const direction = edge === 'left' ? 1 : -1;
      const current = state[edge].open ? state[edge].width : state[edge].minimum - 20;
      if (event.key === 'Home') setWidth(0);
      else if (event.key === 'End') setWidth(state[edge].maximum);
      else setWidth(current + (event.key === 'ArrowRight' ? 20 : -20) * direction);
    });
  }

  mobileButtons.forEach(button => button.addEventListener('click', () => {
    state.mobilePanel = button.dataset.mobileChoice;
    renderPanels();
  }));
  settingsToggle.addEventListener('click', () => {
    settings.hidden = !settings.hidden;
    settingsToggle.setAttribute('aria-expanded', String(!settings.hidden));
  });
  demo.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !settings.hidden) {
      settings.hidden = true;
      settingsToggle.setAttribute('aria-expanded', 'false');
      settingsToggle.focus();
    }
  });
  document.querySelectorAll('[data-theme-choice]').forEach(button => button.addEventListener('click', () => {
    demo.dataset.theme = button.dataset.themeChoice;
    document.querySelectorAll('[data-theme-choice]').forEach(choice => choice.setAttribute('aria-pressed', String(choice === button)));
  }));
  document.querySelector('#font-size').addEventListener('input', event => {
    demo.style.setProperty('--terminal-font', `${event.target.value}px`);
    document.querySelector('#font-value').textContent = `${event.target.value}px`;
  });

  function renderTerminal() {
    const server = servers[state.server];
    const monitor = state.tab === 'monitor';
    const account = monitor && !server.local ? 'ops' : server.account;
    const task = server.local ? (monitor ? 'files' : 'shell') : (monitor ? 'monitor' : 'training');
    document.querySelector('#server-title').textContent = server.name;
    document.querySelector('#connection-kind').textContent = server.local ? 'LOCAL / shell' : 'SSH / tmux';
    document.querySelector('.example-tag').textContent = server.local ? '가상 Mac' : '가상 서버';
    document.querySelector('#terminal-status-name').textContent = `${account} / ${task}`;
    tabs.forEach(button => {
      const selected = button.dataset.tab === state.tab;
      button.setAttribute('aria-selected', String(selected));
      button.tabIndex = selected ? 0 : -1;
      const isMonitor = button.dataset.tab === 'monitor';
      button.textContent = server.local ? `local / ${isMonitor ? 'files' : 'shell'}` : `${isMonitor ? 'ops' : server.account} / ${isMonitor ? 'monitor' : 'training'}`;
    });
    const output = document.querySelector('#terminal-output');
    output.setAttribute('aria-labelledby', monitor ? 'tab-monitor' : 'tab-training');
    const session = server.local ? 'local shell example' : server.idle ? 'session not connected' : 'session attached';
    let content;
    if (server.idle) {
      content = '<div class="muted">열린 터미널이 없는 예제 서버입니다.</div><div class="terminal-gap"></div><div>앱에서는 계정을 선택해 새 작업 탭을 엽니다.</div><div class="muted">이 웹 데모는 실제 SSH 연결을 실행하지 않습니다.</div>';
    } else if (server.local) {
      content = monitor ? '<div><span class="dollar">❯</span> ls ~/Projects</div><div class="terminal-gap"></div><div class="terminal-green">demo-project&nbsp;&nbsp; notes&nbsp;&nbsp; experiments</div>' : '<div><span class="dollar">❯</span> printf "Hello, luluTerminal\\n"</div><div>Hello, luluTerminal</div><div class="terminal-gap"></div><div class="muted">로컬 셸부터, 내 작업 공간의 시작.</div>';
    } else if (monitor) {
      content = '<div><span class="dollar">❯</span> tmux list-sessions</div><div class="terminal-gap"></div><div>training: 1 windows <span class="terminal-green">(attached)</span></div><div>monitor: 1 windows <span class="terminal-green">(attached)</span></div><div class="terminal-gap"></div><div class="muted">작업 탭마다 독립된 원격 세션.</div><div class="muted">계정을 바꿔도, 작업의 자리는 그대로.</div>';
    } else {
      content = '<div><span class="dollar">❯</span> python train.py --config baseline.yaml</div><div class="terminal-gap"></div><div class="muted">[run] Loading dataset ... done</div><div class="muted">[run] Checkpoint restored: epoch 024</div><div class="terminal-gap"></div><div>Epoch <strong>025/100</strong> <span class="muted">━━━━━━━━━━━━</span> <span class="terminal-green">100%</span></div><div class="metrics-output">train_loss <span>0.1842</span> <span class="muted">│</span> val_loss <span>0.2068</span></div><div class="muted">Checkpoint saved → runs/baseline/025</div>';
    }
    // All interpolated values come from the fixed fictional examples above.
    output.innerHTML = `<div class="terminal-session">${session} <span>·</span> ${account} / ${task}</div><div class="terminal-line"><span class="prompt">${account}@${server.local ? 'demo-mac' : server.name}</span> <span class="muted">${server.local ? '~' : '~/experiments'}</span></div>${content}<div class="terminal-gap"></div><div class="terminal-line"><span class="dollar">❯</span> <span class="cursor" aria-hidden="true"></span></div>`;
    for (const metric of ['cpu', 'ram']) {
      document.querySelector(`#${metric}-value`).innerHTML = `${server[metric]}<small>%</small>`;
      document.querySelector(`#${metric}-value`).nextElementSibling.style.setProperty('--value', `${server[metric]}%`);
    }
    document.querySelector('#net-value').innerHTML = server.local ? '—' : `${server.net}<small>MB/s</small>`;
    document.querySelector('.tiny-network').hidden = Boolean(server.local);
    document.querySelector('.gpu-grid').hidden = Boolean(server.local);
    document.querySelector('.ring-legend').hidden = Boolean(server.local);
    document.querySelector('.gpu-unavailable').hidden = !server.local;
    document.querySelector('.resource-label>span').textContent = server.local ? '미지원' : '2 DEVICES';
    serverButtons.forEach(button => {
      const selected = button.dataset.server === state.server;
      button.classList.toggle('selected', selected);
      button.setAttribute('aria-pressed', String(selected));
    });
  }
  serverButtons.forEach(button => button.addEventListener('click', () => {
    state.server = button.dataset.server;
    state.tab = 'training';
    renderTerminal();
    if (mobile.matches) {
      state.mobilePanel = 'terminal';
      renderPanels();
      document.querySelector('#terminal-output').focus();
    }
  }));
  tabs.forEach((button, index) => {
    button.addEventListener('click', () => { state.tab = button.dataset.tab; renderTerminal(); });
    button.addEventListener('keydown', event => {
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
      state.tab = tabs[next].dataset.tab;
      renderTerminal();
      tabs[next].focus();
    });
  });
  mobile.addEventListener('change', renderPanels);
  window.addEventListener('resize', renderPanels);
  renderPanels();
  renderTerminal();
})();

// Illustrations only: no timers, sensor access, network requests, or persistence.
const samples = {
  system: {
    watts: '18.4', title: 'SYSTEM POWER', status: 'Connected to power', chart: 'System draw', avg: '17.9 W', peak: '24.6 W',
    energy: [['Past Minute', '17.9 W', '298.3 mWh'], ['Past Hour', '15.2 W', '15.20 Wh'], ['Past Day', '11.8 W', '94.40 Wh'],
      ['Past Week', '10.6 W', '593.60 Wh'], ['Past Month', '10.9 W', '2.14 kWh'], ['Past 3 Months', '11.1 W', '5.33 kWh']]
  },
  battery: {
    watts: '12.8', title: 'BATTERY POWER', status: 'Charging battery', chart: 'Battery power', avg: '12.1 W', peak: '15.3 W',
    energy: [['Past Minute', '12.1 W', '201.7 mWh'], ['Past Hour', '9.8 W', '9.80 Wh'], ['Past Day', '7.4 W', '59.20 Wh'],
      ['Past Week', '6.9 W', '386.40 Wh'], ['Past Month', '7.2 W', '1.41 kWh'], ['Past 3 Months', '7.0 W', '3.36 kWh']]
  }
};
const setText = (selector, text) => { document.querySelector(selector).textContent = text; };
function showSample(mode) {
  const sample = samples[mode];
  setText('#hero-watts', sample.watts);
  setText('#menu-watts', `${sample.watts} W`);
  setText('#dash-watts', sample.watts);
  setText('#dash-title', sample.title);
  setText('#dash-status', sample.status);
  setText('#chart-title', sample.chart);
  setText('#dash-avg', sample.avg);
  setText('#dash-peak', sample.peak);
  document.querySelector('#dash-energy').replaceChildren(...sample.energy.map(([label, avg, used]) => {
    const row = document.createElement('div');
    row.innerHTML = `<dt>${label}</dt><dd>${avg}</dd><dd>${used}</dd>`;
    return row;
  }));
}
const modeButtons = [...document.querySelectorAll('[data-mode]')];
modeButtons.forEach(button => button.addEventListener('click', () => {
  modeButtons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  showSample(button.dataset.mode);
}));
showSample('system');
const intervalButtons = [...document.querySelectorAll('[data-interval]')];
intervalButtons.forEach(button => button.addEventListener('click', () => {
  intervalButtons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  const seconds = button.dataset.interval;
  document.querySelector('#interval-caption').textContent = `In the app: a reading every ${seconds} ${seconds === '1' ? 'second' : 'seconds'}.`;
}));

// Energy & Apps window illustration (sample data, matches the menu sample above).
const periods = {
  minute: { label: 'Past Minute', wh: 0.2983, avg: 17.9, peak: 24.6, recorded: '1m', coverage: 1, axis: ['40:15', '40:30', '40:45', '41:00'] },
  hour: { label: 'Past Hour', wh: 15.2, avg: 15.2, peak: 31.2, recorded: '1h 0m', coverage: 1, axis: ['8:45', '9:00', '9:15', '9:30'] },
  day: { label: 'Past Day', wh: 94.4, avg: 11.8, peak: 38.5, recorded: '8h 0m', coverage: 8 / 24, axis: ['12:00', '18:00', '00:00', '06:00'] },
  week: { label: 'Past Week', wh: 593.6, avg: 10.6, peak: 41.0, recorded: '2d 8h', coverage: 56 / 168, axis: ['18 Oct', '20 Oct', '22 Oct', '23 Oct'] },
  month: { label: 'Past Month', wh: 2140, avg: 10.9, peak: 44.7, recorded: '8d 4h', coverage: 196 / 720, axis: ['28 Sep', '5 Oct', '12 Oct', '19 Oct'] },
  threeMonths: { label: 'Past 3 Months', wh: 5330, avg: 11.1, peak: 44.7, recorded: '20d 0h', coverage: 480 / 2160, axis: ['1 Aug', '22 Aug', '12 Sep', '3 Oct'] }
};
const chartDescriptions = { minute: 'The last 60 seconds', hour: 'The last 60 minutes', day: 'The last 24 hours',
  week: 'The last 7 days', month: 'The last 30 days', threeMonths: 'The last 90 days' };
const coverageText = value => value > 0 && value < 0.01 ? '<1%' : `${Math.min(100, Math.floor(value * 100))}%`;
// CPU energy per app during the sample hour; other periods scale with total energy.
const apps = [['Xcode', 'X', 142, 3.84], ['Safari', 'S', 61, 2.10], ['Music', 'M', 12, 0.62], ['Mail', 'M', 6, 0.31],
  ['Photos', 'P', 5, 0.24], ['Notes', 'N', 2, 0.09]];
const pageCopy = {
  overview: ['Energy overview', 'A clear view of what your Mac is using.'],
  applications: ['Applications', 'Understand the work behind your energy use.'],
  history: ['History', 'Your recorded usage, over time.']
};
const formatEnergy = wh => wh >= 1000 ? `${(wh / 1000).toFixed(2)} kWh` : wh < 1 ? `${(wh * 1000).toFixed(1)} mWh` : `${wh.toFixed(2)} Wh`;
let period = 'hour';
const cell = (tag, text, className) => { const el = document.createElement(tag); el.textContent = text; if (className) el.className = className; return el; };
function appRows(limit, filter = '') {
  const scale = periods[period].wh / periods.hour.wh;
  return apps.filter(([name]) => name.toLowerCase().includes(filter.toLowerCase())).slice(0, limit)
    .map(([name, letter, cpu, wh]) => ({ name, letter, cpu, wh: wh * scale }));
}
function renderWindow() {
  const p = periods[period];
  setText('#ew-energy', formatEnergy(p.wh));
  setText('#ew-avg', `${p.avg.toFixed(1)} W`);
  setText('#ew-avg-caption', p.label);
  setText('#ew-peak', `${p.peak.toFixed(1)} W`);
  document.querySelectorAll('.ew-chart-desc').forEach(el => { el.textContent = chartDescriptions[period]; });
  document.querySelectorAll('.ew-recorded').forEach(el => { el.textContent = `${p.recorded} recorded`; });
  document.querySelectorAll('.ew-cov-text').forEach(el => { el.textContent = `${coverageText(p.coverage)} of this period`; });
  document.querySelectorAll('.ew-cov').forEach(el => el.style.setProperty('--cov', `${p.coverage * 100}%`));
  document.querySelectorAll('.ew-x').forEach(el => el.replaceChildren(...p.axis.map(label => cell('span', label))));
  setText('#ew-top-caption', `CPU energy · ${p.label.toLowerCase()}`);
  setText('#ew-observed', `${p.recorded} observed`);
  const top = appRows(3);
  const max = Math.max(...top.map(app => app.wh));
  document.querySelector('#ew-top').replaceChildren(...top.map(app => {
    const row = cell('div', '', 'ew-top-row');
    const bar = cell('span', '', 'ew-bar');
    bar.style.setProperty('--fill', `${(app.wh / max) * 100}%`);
    row.append(cell('span', app.letter, 'ew-icon'), cell('span', app.name), bar, cell('b', formatEnergy(app.wh)));
    return row;
  }));
  renderApps();
  document.querySelector('#ew-history').replaceChildren(...Object.entries(periods).map(([key, item]) => {
    const row = cell('button', '', `ew-row four${key === period ? ' selected' : ''}`);
    row.type = 'button';
    row.dataset.period = key;
    row.append(cell('span', item.label), cell('span', formatEnergy(item.wh), 'accent'), cell('span', `${item.avg.toFixed(1)} W`), cell('span', item.recorded, 'muted'));
    return row;
  }));
  document.querySelectorAll('.ew-periods [data-period]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.period === period)));
}
function renderApps() {
  const rows = appRows(apps.length, document.querySelector('#ew-search').value);
  setText('#ew-count', `${rows.length} ${rows.length === 1 ? 'application' : 'applications'}`);
  const list = document.querySelector('#ew-apps');
  if (!rows.length) { list.replaceChildren(cell('p', 'No matching applications', 'ew-empty')); return; }
  list.replaceChildren(...rows.map(app => {
    const row = cell('div', '', 'ew-row');
    const name = cell('span', '');
    name.append(cell('span', app.letter, 'ew-icon'), document.createTextNode(app.name));
    row.append(name, cell('span', `${app.cpu}%`), cell('b', formatEnergy(app.wh)));
    return row;
  }));
}
document.querySelector('.energy-window').addEventListener('click', event => {
  const target = event.target.closest('[data-page], [data-period]');
  if (!target) return;
  if (target.dataset.period) { period = target.dataset.period; renderWindow(); return; }
  const page = target.dataset.page;
  document.querySelectorAll('.ew-nav [data-page]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.page === page)));
  document.querySelectorAll('.ew-page').forEach(view => { view.hidden = view.dataset.view !== page; });
  setText('#ew-title', pageCopy[page][0]);
  setText('#ew-subtitle', pageCopy[page][1]);
});
document.querySelector('#ew-search').addEventListener('input', renderApps);
renderWindow();

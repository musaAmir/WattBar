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

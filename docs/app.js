// Illustrations only: no timers, sensor access, network requests, or persistence.
const modeButtons = [...document.querySelectorAll('[data-mode]')];
modeButtons.forEach(button => button.addEventListener('click', () => {
  modeButtons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  const watts = button.dataset.mode === 'battery' ? '12.8' : '18.4';
  document.querySelector('#hero-watts').textContent = watts;
  document.querySelector('#menu-watts').textContent = `${watts} W`;
}));
const intervalButtons = [...document.querySelectorAll('[data-interval]')];
intervalButtons.forEach(button => button.addEventListener('click', () => {
  intervalButtons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  const seconds = button.dataset.interval;
  document.querySelector('#interval-caption').textContent = `In the app: a reading every ${seconds} ${seconds === '1' ? 'second' : 'seconds'}.`;
}));

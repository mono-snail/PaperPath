(() => {
  const tabs = [...document.querySelectorAll('[data-tab]')];
  const image = document.querySelector('#privacy-screen');
  const images = image?.dataset.images.split('|') ?? [];
  const alts = image?.dataset.alts.split('|') ?? [];
  const select = (index, focus = false) => {
    tabs.forEach((tab, i) => {
      tab.setAttribute('aria-selected', String(i === index));
      tab.tabIndex = i === index ? 0 : -1;
      document.getElementById(tab.getAttribute('aria-controls')).hidden = i !== index;
    });
    if (image && images[index]) { image.src = images[index]; image.alt = alts[index]; }
    if (focus) tabs[index].focus();
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(i));
    tab.addEventListener('keydown', event => {
      let next;
      if (event.key === 'ArrowRight') next = (i + 1) % tabs.length;
      if (event.key === 'ArrowLeft') next = (i + tabs.length - 1) % tabs.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = tabs.length - 1;
      if (next !== undefined) { event.preventDefault(); select(next, true); }
    });
  });
  document.addEventListener('click', event => {
    document.querySelectorAll('.language[open]').forEach(menu => {
      if (!menu.contains(event.target)) menu.open = false;
    });
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') document.querySelectorAll('.language[open]').forEach(menu => {
      menu.open = false; menu.querySelector('summary').focus();
    });
  });
})();

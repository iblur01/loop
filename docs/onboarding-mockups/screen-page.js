/* ==========================================================================
   Rendu d'une page d'écran individuelle (01-welcome.html .. 08-ready.html)
   Affiche : Version Claire + Version Sombre + État Vide/Erreur (Clair & Sombre)
   ========================================================================== */
(function () {
  var stepIndex = typeof window.CURRENT_STEP_INDEX === 'number' ? window.CURRENT_STEP_INDEX : 0;
  var screen = window.LOOP_SCREENS[stepIndex] || window.LOOP_SCREENS[0];
  var state = {
    lang: 'bilingual',
    dynamicType: 'standard',
    reduceTransparency: false
  };

  var stageEl = document.getElementById('phones-stage');
  var navStripEl = document.getElementById('screen-strip');

  function renderStrip() {
    if (!navStripEl) return;
    var pills = window.LOOP_SCREENS.map(function (s, idx) {
      var active = idx === stepIndex ? ' active' : '';
      var current = idx === stepIndex ? ' aria-current="step"' : '';
      var label = state.lang === 'en' ? s.shortNameEn : s.shortNameFr;
      return '<a class="wb-step-pill' + active + '"' + current + ' href="' + s.file + '">' + label + '</a>';
    }).join('');
    var backLabel = state.lang === 'en' ? '← Full flow (index.html)' : '← Parcours complet (index.html)';
    navStripEl.innerHTML = (
      '<a class="wb-step-pill" href="index.html">' + backLabel + '</a>' +
      pills +
      '<a class="wb-step-pill" href="PLAN.md" style="margin-left:auto;">PLAN.md</a>'
    );
  }

  function renderPhones() {
    if (!stageEl) return;
    stageEl.innerHTML = (
      '<div class="phone-column">' +
        '<div class="phone-caption">1. Version Claire (État nominal)</div>' +
        window.renderPhoneHTML(stepIndex, {
          theme: 'light',
          state: 'nominal',
          lang: state.lang,
          dynamicType: state.dynamicType,
          reduceTransparency: state.reduceTransparency,
          interactiveNav: false
        }) +
      '</div>' +
      '<div class="phone-column">' +
        '<div class="phone-caption">2. Version Sombre (État nominal)</div>' +
        window.renderPhoneHTML(stepIndex, {
          theme: 'dark',
          state: 'nominal',
          lang: state.lang,
          dynamicType: state.dynamicType,
          reduceTransparency: state.reduceTransparency,
          interactiveNav: false
        }) +
      '</div>' +
      '<div class="phone-column">' +
        '<div class="phone-caption">3. État Vide / Erreur (Clair)</div>' +
        window.renderPhoneHTML(stepIndex, {
          theme: 'light',
          state: 'error',
          lang: state.lang,
          dynamicType: state.dynamicType,
          reduceTransparency: state.reduceTransparency,
          interactiveNav: false
        }) +
      '</div>' +
      '<div class="phone-column">' +
        '<div class="phone-caption">4. État Vide / Erreur (Sombre)</div>' +
        window.renderPhoneHTML(stepIndex, {
          theme: 'dark',
          state: 'error',
          lang: state.lang,
          dynamicType: state.dynamicType,
          reduceTransparency: state.reduceTransparency,
          interactiveNav: false
        }) +
      '</div>'
    );

    var prevScreen = stepIndex > 0 ? window.LOOP_SCREENS[stepIndex - 1] : null;
    var nextScreen = stepIndex < window.LOOP_SCREENS.length - 1 ? window.LOOP_SCREENS[stepIndex + 1] : window.LOOP_SCREENS[0];

    stageEl.querySelectorAll('[data-action="prev"]').forEach(function (btn) {
      if (!prevScreen) {
        btn.disabled = true;
      } else {
        btn.addEventListener('click', function () {
          window.location.href = prevScreen.file;
        });
      }
    });

    stageEl.querySelectorAll('[data-action="next"], [data-action="secondary"]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        window.location.href = nextScreen.file;
      });
    });

    window.bindPhoneInteractions(stageEl);
  }

  document.querySelectorAll('[data-lang-select]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      state.lang = btn.getAttribute('data-lang-select');
      document.querySelectorAll('[data-lang-select]').forEach(function (b) {
        var active = b === btn;
        b.classList.toggle('active', active);
        b.setAttribute('aria-pressed', active ? 'true' : 'false');
      });
      renderStrip();
      renderPhones();
    });
  });

  var dtBtn = document.getElementById('toggle-dt');
  if (dtBtn) {
    dtBtn.addEventListener('click', function () {
      state.dynamicType = state.dynamicType === 'standard' ? 'large' : 'standard';
      var isLarge = state.dynamicType === 'large';
      dtBtn.classList.toggle('active', isLarge);
      dtBtn.setAttribute('aria-pressed', isLarge ? 'true' : 'false');
      renderPhones();
    });
  }

  var rtBtn = document.getElementById('toggle-rt');
  if (rtBtn) {
    rtBtn.addEventListener('click', function () {
      state.reduceTransparency = !state.reduceTransparency;
      rtBtn.classList.toggle('active', state.reduceTransparency);
      rtBtn.setAttribute('aria-pressed', state.reduceTransparency ? 'true' : 'false');
      renderPhones();
    });
  }

  renderStrip();
  renderPhones();
})();

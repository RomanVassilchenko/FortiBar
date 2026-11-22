// FortiBar site: footer year and copy buttons. Nothing else runs on the page.
(function () {
  'use strict';

  var year = document.getElementById('year');
  if (year) year.textContent = new Date().getFullYear();

  document.querySelectorAll('.copy[data-copy]').forEach(function (btn) {
    var label = btn.querySelector('.sr-only');
    var timer;

    function show(text, copied) {
      if (label) label.textContent = text;
      btn.title = text;
      btn.classList.toggle('is-copied', copied);
      clearTimeout(timer);
      timer = setTimeout(function () {
        if (label) label.textContent = 'Copy';
        btn.title = 'Copy';
        btn.classList.remove('is-copied');
      }, 1600);
    }

    // Without clipboard access, select the command so ⌘C works
    function select() {
      var code = btn.parentNode.querySelector('code');
      if (!code) return;
      var range = document.createRange();
      range.selectNodeContents(code);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      show('Press ⌘C to copy', false);
    }

    btn.addEventListener('click', function () {
      var text = btn.getAttribute('data-copy');
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { show('Copied', true); }, select);
      } else {
        select();
      }
    });
  });
})();

import Foundation

enum MistPasswordPageScript {
    static let world = "mist-pw"
    static let binding = "__mistPwMessage"
    static let source = #"""
    (() => {
      if (window !== window.top) return;
      if (window.__mistPwInstalled) { window.__mistPwRefresh(); return; }
      window.__mistPwInstalled = true;
      const fields = new Map(), ids = new WeakMap();
      let nextID = 1, dropdown = false, focused = null, dismissed = null, frame = 0, submitted = null;
      let lastSubmission = '', lastTime = 0, observer = null, expiry = null;
      const post = value => { try { window.__mistPwMessage(JSON.stringify(value)); } catch (_) {} };
      const visible = el => el && el.isConnected && !el.disabled && !el.readOnly &&
        [...el.getClientRects()].some(rect => rect.width > 0 && rect.height > 0) &&
        getComputedStyle(el).visibility !== 'hidden';
      const token = (el, value) => el.autocomplete.toLowerCase().split(/\s+/).includes(value);
      const password = el => el instanceof HTMLInputElement && el.type === 'password';
      const codeInput = el => el instanceof HTMLInputElement &&
        ['text', 'tel', 'number', 'password'].includes(el.type) && visible(el);
      function codeGroup(el) {
        if (!codeInput(el) || el.maxLength !== 1) return [el];
        for (const parent of [el.parentElement, el.parentElement?.parentElement]) {
          if (!parent) continue;
          const group = [...parent.querySelectorAll('input')].filter(input => codeInput(input) && input.maxLength === 1);
          if (group.length >= 4 && group.length <= 8 && group.includes(el)) return group;
        }
        return [el];
      }
      const codeText = el => [el.name, el.id, el.placeholder, el.getAttribute('aria-label'),
        ...[...el.labels || []].map(label => label.textContent)].join(' ');
      const codeWords = el =>
        /otp|one-?time|verification|verify|security.?code|passcode|2fa|mfa|\bcode\b|\bpin\b/i.test(codeText(el)) &&
        !/postal|zip|post.?code|promo|coupon|voucher|gift|discount|referral|invite|country|area|dial/i.test(codeText(el)) &&
        !['postal-code', 'tel-country-code', 'tel-area-code'].some(value => token(el, value));
      // Words alone don't make a password input a code: Okta names its password field credentials.passcode.
      const codeShaped = el => !password(el) || (!token(el, 'current-password') && !token(el, 'new-password') &&
        ((el.maxLength >= 4 && el.maxLength <= 8) || el.inputMode === 'numeric'));
      const codeField = el => codeInput(el) && (token(el, 'one-time-code') || codeGroup(el).length > 1 ||
        (codeWords(el) && codeShaped(el)));
      const username = el => el instanceof HTMLInputElement && ['text', 'email', 'tel'].includes(el.type) &&
        !codeField(el) && !token(el, 'one-time-code') && !/otp|one-?time|code/i.test(`${el.name} ${el.id}`);
      const userish = el => username(el) && (el.type === 'email' ||
        ['username', 'email', 'webauthn'].some(value => token(el, value)) ||
        /user|e-?mail|login|account|identifier/i.test(
          [el.name, el.id, el.placeholder, el.getAttribute('aria-label'),
            ...[...el.labels || []].map(label => label.textContent)].join(' ')));
      const emailField = el => el instanceof HTMLInputElement && ['text', 'email'].includes(el.type) &&
        visible(el) && !token(el, 'one-time-code') && (el.type === 'email' || token(el, 'email') ||
          /e-?mail/i.test([el.name, el.id, el.placeholder, el.getAttribute('aria-label'),
            ...[...el.labels || []].map(label => label.textContent)].join(' ')));
      const id = el => {
        if (!ids.has(el)) ids.set(el, nextID++);
        fields.set(ids.get(el), el);
        return ids.get(el);
      };
      function pair(pw) {
        if (!password(pw) || !visible(pw) || codeField(pw)) return null;
        const scope = pw.form || document;
        const candidates = [...scope.querySelectorAll('input')].filter(el =>
          username(el) && visible(el) && el.form === pw.form &&
          !!(el.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING));
        const preferred = candidates.filter(el => /^(username|email)$/i.test(el.autocomplete));
        const user = (preferred.length ? preferred : candidates).at(-1);
        return user ? {user, pw, hint: ''} : null;
      }
      function usernameOnly(el) {
        if (!visible(el) || !userish(el) || token(el, 'new-password') ||
            [...(el.form || document).querySelectorAll('input[type="password"]')].some(visible)) return null;
        return {user: el, pw: null, hint: ''};
      }
      function passwordOnly(pw) {
        if (!password(pw) || !visible(pw) || codeField(pw) || token(pw, 'new-password')) return null;
        const scope = pw.form || document;
        if ([...scope.querySelectorAll('input[type="password"]')].filter(visible).length !== 1) return null;
        const hint = [...scope.querySelectorAll('input')].filter(el => el.form === pw.form && el.value &&
          !!(el.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) &&
          (userish(el) || (el.type === 'hidden' && (token(el, 'username') ||
            /user|e-?mail|login|identifier/i.test(`${el.name} ${el.id}`))))).at(-1)?.value || '';
        return {user: null, pw, hint};
      }
      function login(el) {
        if (codeField(el)) return null;
        if (password(el)) return pair(el) || passwordOnly(el);
        if (!username(el)) return null;
        for (const pw of (el.form || document).querySelectorAll('input[type="password"]')) {
          const result = pair(pw);
          if (result && result.user === el) return result;
        }
        return usernameOnly(el);
      }
      const mode = result => result.user ? (result.pw ? 'login' : 'username') : 'password';
      function focus() {
        for (const [key, el] of fields) if (!el.isConnected) fields.delete(key);
        const el = document.activeElement, result = login(el);
        const usable = result && !token(result.pw || el, 'new-password') && !token(el, 'new-password');
        const isCode = !usable && !emailField(el) && codeField(el);
        if (!usable && !emailField(el) && !isCode) {
          focused = null; dropdown = false; post({type: 'blur'}); return;
        }
        focused = el;
        if (el === dismissed) return;
        const rect = el.getBoundingClientRect();
        post({type: 'focus', fieldId: id(el), kind: isCode ? 'code' : usable ? (password(el) ? 'password' : 'username') : 'email',
          mode: isCode ? 'code' : usable ? mode(result) : 'email', hint: result?.hint || '',
          length: isCode ? (codeGroup(el).length > 1 ? codeGroup(el).length :
            el.maxLength >= 4 && el.maxLength <= 8 ? el.maxLength : 0) : 0,
          rect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height}, dpr: devicePixelRatio});
      }
      function geometry() {
        if (frame || !focused) return;
        frame = requestAnimationFrame(() => { frame = 0; focus(); });
      }
      function capture(result) {
        if (!result) return;
        if (!result.pw) {
          if (result.user.value) post({type: 'identifier', username: result.user.value});
          return;
        }
        if (!result.pw.value) return;
        const user = result.user ? result.user.value : result.hint;
        const signature = JSON.stringify([user, result.pw.value]);
        if (signature === lastSubmission && Date.now() - lastTime < 1000) return;
        lastSubmission = signature; lastTime = Date.now(); submitted = result.pw;
        post({type: 'submitted', mode: mode(result), username: user, password: result.pw.value});
        observer?.disconnect(); clearTimeout(expiry);
        observer = new MutationObserver(() => {
          if (submitted && (!submitted.isConnected || submitted.getClientRects().length === 0 ||
              getComputedStyle(submitted).visibility === 'hidden')) {
            post({type: 'formGone'}); clearSubmission();
          }
        });
        observer.observe(document, {subtree: true, childList: true, attributes: true});
        expiry = setTimeout(clearSubmission, 30000);
      }
      function clearSubmission() {
        observer?.disconnect(); observer = null; submitted = null; lastSubmission = ''; clearTimeout(expiry);
      }
      document.addEventListener('focusin', focus, true);
      document.addEventListener('focusout', () => {
        focused = null; dismissed = null; dropdown = false; post({type: 'blur'});
      }, true);
      // Typing closes the dropdown so Enter submits what was typed; clearing the field reopens it.
      document.addEventListener('input', event => {
        if (!event.isTrusted || focused !== event.target) return;
        if (event.target.value) {
          if (dismissed !== focused) { dismissed = focused; dropdown = false; post({type: 'blur'}); }
        } else if (dismissed === focused) {
          dismissed = null; focus();
        }
      }, true);
      document.addEventListener('scroll', geometry, true);
      window.addEventListener('resize', geometry);
      document.addEventListener('keydown', event => {
        if (!event.isTrusted) return;
        // A passive dropdown (no saved logins) leaves Enter and arrows to the page.
        const keys = dropdown === 'passive' ? ['Escape'] : ['ArrowUp', 'ArrowDown', 'Enter', 'Escape'];
        if (dropdown && focused === event.target && keys.includes(event.key)) {
          event.preventDefault(); event.stopImmediatePropagation(); post({type: 'key', key: event.key});
        } else if (event.key === 'Escape' && focused && codeField(focused)) {
          dismissed = focused; dropdown = false; post({type: 'blur'});
        } else if (event.key === 'Enter') {
          const result = login(event.target);
          if (password(event.target) || (result && !result.pw)) capture(result);
        }
      }, true);
      document.addEventListener('submit', event => {
        const passwords = [...event.target.querySelectorAll('input[type="password"]')].filter(visible);
        const pw = passwords.find(el => token(el, 'new-password')) || passwords[0];
        if (pw) capture(login(pw));
        else capture(usernameOnly([...event.target.querySelectorAll('input')].filter(el => visible(el) && userish(el)).at(-1)));
      }, true);
      document.addEventListener('click', event => {
        if (!event.isTrusted) return;
        const button = event.target.closest('button,input[type="submit"],input[type="image"],[role="button"]');
        if (!button || (button instanceof HTMLButtonElement && button.type === 'reset') ||
            button.hasAttribute('aria-pressed') || /show|hide|reveal|visib|toggle/i.test(
              [button.getAttribute('aria-label'), button.title, button.textContent].join(' '))) return;
        let scope = button.form || button.parentElement;
        while (scope && !scope.querySelector('input[type="password"]')) scope = scope.parentElement;
        const passwords = scope ? [...scope.querySelectorAll('input[type="password"]')].filter(visible) : [];
        if (passwords.length) {
          const pw = passwords.find(el => token(el, 'new-password')) || passwords[0];
          // Direct children of the form can be ordinary Continue controls.
          if (button.parentElement === pw.parentElement && button.parentElement !== pw.form) return;
          capture(login(pw));
        } else {
          scope = button.form || button.parentElement;
          while (scope) {
            const user = [...scope.querySelectorAll('input')].filter(el => visible(el) && userish(el)).at(-1);
            if (user) { capture(usernameOnly(user)); break; }
            scope = scope.parentElement;
          }
        }
      }, true);
      window.__mistPwSetDropdownOpen = value => { dropdown = value === 'passive' ? value : !!value; };
      window.__mistPwRefresh = () => { dropdown = false; focus(); };
      window.__mistPwFillCode = (fieldId, code) => {
        const field = fields.get(fieldId);
        if (document.activeElement !== field || !codeField(field)) return {ok: false};
        const group = codeGroup(field);
        if (group.length > 1 && group.length !== code.length) return {ok: false};
        if (group.length === 1 && field.maxLength >= 4 && field.maxLength <= 8 &&
            field.maxLength !== code.length) return {ok: false};
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        for (const [index, input] of group.entries()) {
          if (!codeInput(input)) return {ok: false};
          const value = group.length > 1 ? code[index] : code;
          setter.call(input, value);
          if (input.value !== value) return {ok: false};
          input.dispatchEvent(new Event('input', {bubbles: true}));
          input.dispatchEvent(new Event('change', {bubbles: true}));
        }
        return {ok: true};
      };
      window.__mistPwFillField = (fieldId, value) => {
        const field = fields.get(fieldId);
        if (document.activeElement !== field || !visible(field) ||
            !(emailField(field) || login(field)?.user === field)) return {ok: false};
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(field, value);
        field.dispatchEvent(new Event('input', {bubbles: true}));
        field.dispatchEvent(new Event('change', {bubbles: true}));
        return {ok: true};
      };
      window.__mistPwFill = (fieldId, user, secret) => {
        const field = fields.get(fieldId), result = login(field);
        if (!result || document.activeElement !== field || (result.pw && token(result.pw, 'new-password'))) return {ok: false};
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        for (const [el, value] of [[result.user, user], [result.pw, secret]]) {
          if (!el) continue;
          setter.call(el, value);
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
        }
        return {ok: true};
      };
      focus();
    })();
    """#

    static func literal(_ value: String) -> String {
        // JSON serialization escapes control characters and script delimiters without interpolation.
        String(data: try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), encoding: .utf8)!
    }
}

#!/usr/bin/env node
// Self-test for Cloudflare challenge detection (detectChallenge's in-page
// function). Run after changing it:
//   node scripts/selftest-challenge.mjs
//
// Everything runs against fixture pages modeled as plain objects — no Phi
// needed. Exits non-zero when any check fails.

import { __cloudflareChallengeForTest as detect } from './lib/helpers.mjs'

// Run the detector's serialized source, as the page does, against a fixture.
// `elements` maps each simple selector the page matches to its element.
function run({ title = '', text = '', elements = {}, setup } = {}) {
  const window = {}
  if (setup) setup(window)
  const document = {
    title,
    body: { innerText: text },
    querySelector: (sel) => {
      for (const one of sel.split(',').map(s => s.trim())) {
        if (elements[one]) return elements[one]
      }
      return null
    },
  }
  const location = { href: 'https://app.example.com/' }
  return new Function('window', 'document', 'location',
    `return (${detect.toString()})()`)(window, document, location)
}

// The first statement of Cloudflare's scripts/precursor/main.js (Bot
// Management's page script), verbatim but for the window parameter.
const precursorPrologue = (window) => {
  (function(){var o=window._cf_chl_opt||{};window._cf_chl_opt=o.pi!==undefined?o:{};if(o.pi!==undefined){window._cf_chl_opt.pi=o.pi;}if(o.pp!==undefined){window._cf_chl_opt.pp=o.pp;}if(o.bRaA0!==undefined){window._cf_chl_opt.bRaA0=o.bRaA0;}if(o.idQN5!==undefined){window._cf_chl_opt.idQN5=o.idQN5;}window._cf_chl_opt.ppebL7="g";})()
}

let failed = 0
function check(name, actual, expected) {
  const ok = JSON.stringify(actual?.kind ?? null) === JSON.stringify(expected?.kind ?? null) &&
    (!expected || actual.evidence === expected.evidence)
  if (!ok) failed++
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : ` — got ${JSON.stringify(actual)}`}`)
}

check('healthy page running Cloudflare precursor is not a challenge',
  run({ title: 'Acme Platform', text: 'Good afternoon, Ada Hubs Groups',
        setup: precursorPrologue }), null)

check('healthy page running JS Detections is not a challenge',
  run({ title: 'Claude', text: 'How can I help you today?',
        setup: (w) => { w._cf_chl_opt = { ppebL7: 'g' } } }), null)

check('managed interstitial config is an interstitial',
  run({ title: 'Just a moment...', text: '',
        setup: (w) => { w._cf_chl_opt = { cvId: '3', cZone: 'app.example.com',
          cType: 'managed', cRay: '8f1c2d3e4f5a6b7c', cH: 'x', cFPWv: 'g' } } }),
  { kind: 'interstitial', evidence: '_cf_chl_opt' })

check('challenge stage DOM is an interstitial',
  run({ title: 'Just a moment...', elements: { '#challenge-stage': {} } }),
  { kind: 'interstitial', evidence: 'challenge-dom' })

check('challenge copy under the challenge title is an interstitial',
  run({ title: 'Just a moment...',
        text: 'app.example.com Verifying you are human. This may take a few seconds.' }),
  { kind: 'interstitial', evidence: 'title-and-copy' })

check('stale challenge title alone is not a challenge',
  run({ title: 'Just a moment...', text: 'The application is ready.' }), null)

check('Cloudflare block page is blocked',
  run({ title: 'Attention Required! | Cloudflare', elements: { '#cf-error-details': {} } }),
  { kind: 'blocked', evidence: 'cf-error-details' })

check('unsolved Turnstile widget is a turnstile challenge',
  run({ title: 'Sign in', elements: { '.cf-turnstile': {},
        'input[name="cf-turnstile-response"]': { value: '' } } }),
  { kind: 'turnstile', evidence: 'turnstile-widget' })

check('solved Turnstile widget is not a challenge',
  run({ title: 'Sign in', elements: { '.cf-turnstile': {},
        'input[name="cf-turnstile-response"]': { value: 'token' } } }), null)

if (failed) {
  console.error(`${failed} check(s) failed`)
  process.exit(1)
}
console.log('all challenge detection checks passed')
process.exit(0)

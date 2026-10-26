// Run the real Grok Bot bridge expressions with DOM fixtures using macOS JavaScriptCore.
import Foundation
import JavaScriptCore

let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources/GrokBotHub/Runtime/GrokBotBridge.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)
let context = JSContext()!
var failed = false
context.exceptionHandler = { _, exception in
    failed = true
    FileHandle.standardError.write(Data(("FAIL: \(exception?.toString() ?? "unknown JavaScript error")\n").utf8))
}
let report: @convention(block) (String) -> Void = { print($0) }
context.setObject(report, forKeyedSubscript: "report" as NSString)
context.setObject(source, forKeyedSubscript: "bridgeSource" as NSString)
context.evaluateScript(#"""
const stateJS = bridgeSource.split('private static let computerStateJS = """')[1].split('"""')[0];
const clickJS = bridgeSource.split('private func clickIf(')[1].split('"""')[1];
const actionTarget = name => bridgeSource.split(`func ${name}(`)[1].match(/clickIf\("(.*?)"\)/s)[1];

function equal(actual, expected, label = '') {
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, got ${actual}`);
}
function test(name, body) {
  body();
  report(`PASS ${name}`);
}

function button(text, disabled = false) {
  return {
    innerText: text, disabled, title: '', clicks: 0,
    getAttribute() { return null; },
    click() { this.clicks++; },
  };
}

function fixture({ pane = 'preview', text = '', open = button('打开电脑'), buttons = [], bar = true, body = '' } = {}) {
  const scope = {
    innerText: text,
    querySelectorAll() { return buttons; },
    querySelector(selector) { return selector === '.sand-computer-control-bar' && bar ? {} : null; },
  };
  const document = {
    body: { innerText: body },
    querySelector(selector) {
      if (selector === '.sand-computer-preview') return pane === 'preview' ? scope : null;
      if (selector === '.sand-computer-fullscreen') return pane === 'fullscreen' ? scope : null;
      if (selector === '.sand-computer-preview__open') return pane === 'preview' ? open : null;
      return null;
    },
  };
  return {
    state: () => new Function('document', `${stateJS}; return state;`)(document),
    click: name => new Function('document', `return (${clickJS
      .replace('\\(Self.computerStateJS)', stateJS)
      .replace('\\(target)', actionTarget(name))})`)(document),
  };
}

test('recognizes preview and fullscreen without reading unrelated chat text', () => {
  equal(fixture({ body: 'Computer is asleep，正在唤醒' }).state(), 'awake');
  equal(fixture({ pane: 'fullscreen', text: '仅观看\n取得控制权' }).state(), 'awake');
  equal(fixture({ pane: 'fullscreen', text: 'Watching\nTake control', bar: false }).state(), 'awake');
  equal(fixture({ pane: 'fullscreen', bar: false }).state(), 'unrecognizedFullscreen');
  equal(fixture({ pane: 'none' }).state(), 'notShown');
});

test('recognizes sleep, startup, paused screen and failures in supported languages', () => {
  const cases = [
    ['电脑正在休眠', 'asleep'], ['電腦正在休眠', 'asleep'], ['Computer is asleep', 'asleep'],
    ['正在唤醒', 'waking'], ['正在設定', 'waking'], ['Starting desktop', 'waking'], ['Connecting', 'waking'],
    ['屏幕已暂停', 'away'], ['螢幕已暫停', 'away'], ['Screen paused', 'away'],
    ['无法连接', 'unreachable'], ['無法連上', 'unreachable'], ["Couldn't reach computer", 'unreachable'],
    ['电脑正在重建', 'paused'], ['電腦已暫時暫停', 'paused'], ['Computer is temporarily paused', 'paused'],
    ['在此设备上运行', 'onDevice'], ['在此裝置上執行', 'onDevice'], ['Works on this device', 'onDevice'],
  ];
  for (const [text, expected] of cases) {
    for (const pane of ['preview', 'fullscreen']) {
      equal(fixture({ pane, text, bar: false, open: null }).state(), expected, `${pane}: ${text}`);
    }
  }
  equal(fixture({ pane: 'none', body: 'Computer is temporarily paused' }).state(), 'paused');
});

test('only clicks an enabled wake button while asleep', () => {
  const wake = button('唤醒电脑');
  const asleep = fixture({ open: wake });
  equal(asleep.state(), 'asleep');
  equal(asleep.click('clickWakeComputer'), true);
  equal(wake.clicks, 1);
  const disabled = button('Wake computer', true);
  const waking = fixture({ open: disabled });
  equal(waking.state(), 'waking');
  equal(waking.click('clickWakeComputer'), false);
  equal(disabled.clicks, 0);
  const open = button('打开电脑');
  equal(fixture({ open }).click('clickWakeComputer'), false);
  equal(open.clicks, 0);
});

test('retry stays inside the computer pane and respects disabled controls', () => {
  for (const label of ['重试', '重試', '再試一次', 'Retry', 'Try again']) {
    const retry = button(label);
    equal(fixture({ text: '无法连接', buttons: [retry] }).click('clickRetry'), true);
    equal(retry.clicks, 1);
  }
  const retry = button('Retry', true);
  equal(fixture({ buttons: [retry] }).click('clickRetry'), false);
  equal(fixture({ pane: 'none', buttons: [button('Retry')] }).click('clickRetry'), false);
});

test('fullscreen recovery only exits the computer fullscreen', () => {
  const exit = button('退出全屏');
  equal(fixture({ pane: 'fullscreen', buttons: [exit] }).click('exitComputerFullscreen'), true);
  equal(exit.clicks, 1);
  equal(fixture({ buttons: [exit] }).click('exitComputerFullscreen'), false);
  equal(exit.clicks, 1);
});

"""#)
if failed { exit(1) }

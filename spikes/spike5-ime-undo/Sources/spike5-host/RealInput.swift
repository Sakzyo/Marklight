import AppKit
import EditScenarios

/// Input that only a real browser can resolve: it picks the ranges and the caret.
enum Step {
    case key(String, UInt16, NSEvent.ModifierFlags)
    case click(Int)
    case selectAll
}

let left = Step.key("\u{F702}", 123, [])
let right = Step.key("\u{F703}", 124, [])
let shiftRight = Step.key("\u{F703}", 124, .shift)
let shiftLeft = Step.key("\u{F702}", 123, .shift)
let optionBackspace = Step.key("\u{7F}", 51, .option)
let optionDelete = Step.key("\u{F728}", 117, .option)
let commandBackspace = Step.key("\u{7F}", 51, .command)
func letter(_ c: String) -> Step { .key(c, 0, []) }

let realInput: [(name: String, before: String, steps: [Step], after: String)] = [
    ("option-backspace deletes a word", "hello world‸\n", [optionBackspace], "hello ‸\n"),
    ("option-backspace inside bold hoists the space", "a **hello world‸** b\n", [optionBackspace], "a **hello** ‸ b\n"),
    ("option-backspace across a mark boundary", "a **bold** word‸\n", [optionBackspace, optionBackspace], "a ‸\n"),
    ("option-delete deletes a word forward", "‸hello world\n", [optionDelete], "‸world\n"),
    ("option-backspace on CJK uses the system's word breaks", "前文 中文字符‸\n", [optionBackspace], "前文 中文‸\n"),
    ("command-backspace deletes to line start", "hello wor‸ld\n\nnext\n", [commandBackspace], "‸ld\n\nnext\n"),
    ("arrow right then type", "ab‸cd\n", [right, letter("X")], "abcX‸d\n"),
    ("arrow left over an emoji", "a👍🏽‸b\n", [left, letter("X")], "aX‸👍🏽b\n"),
    ("arrow right into bold", "fo‸o **bar**\n", [right, right, right, letter("X")], "foo **bX‸ar**\n"),
    ("arrow right past an escape", "a‸\\*b\n", [right, letter("X")], "a\\*X‸b\n"),
    ("arrow right past an entity", "a‸&amp;b\n", [right, letter("X")], "a&amp;X‸b\n"),
    ("arrow right across a soft break", "a‸\nb\n", [right, letter("X")], "a\nX‸b\n"),
    ("arrow right to the next block", "a‸\n\nb\n", [right, letter("X")], "a\n\nX‸b\n"),
    ("shift-select then type", "ab‸cd\n", [shiftRight, shiftRight, letter("X")], "abX‸\n"),
    ("shift-select across a mark then delete", "a‸b **cd** e\n", [shiftRight, shiftRight, shiftRight, Step.key("\u{7F}", 51, [])], "a‸**d** e\n"),
    ("shift-select backwards across a mark", "**ab** cd‸\n", [shiftLeft, shiftLeft, shiftLeft, shiftLeft, Step.key("\u{7F}", 51, [])], "**a‸**\n"),
    ("shift-select then bold", "a‸bc d\n", [shiftRight, shiftRight, Step.key("b", 11, .command)], "a**bc‸** d\n"),
    ("click in text then type", "hello world\n", [.click(6), letter("X")], "hello X‸world\n"),
    ("click in bold then type", "a **bold** b\n", [.click(6), letter("X")], "a **boX‸ld** b\n"),
    ("click in a code span then type", "a `code` b\n", [.click(5), letter("X")], "a `coX‸de` b\n"),
    ("click in a list then enter", "- one\n- two\n", [.click(9), Step.key("\r", 36, [])], "- one\n- t\n- ‸wo\n"),
    ("click in a table cell then type", "| ab |\n|---|\n| cd |\n", [.click(16), letter("X")], "| ab |\n|---|\n| cX‸d |\n"),
    ("select all then type", "# a\n\nb **c**\n\n- d\n", [.selectAll, letter("X")], "# X‸\n"),
    ("select all then delete", "a\n\nb\n", [.selectAll, Step.key("\u{7F}", 51, [])], "‸\n"),
    ("spoofed offsets in raw HTML are stripped", "<div data-src=\"0:1\" data-run contenteditable=\"true\"><input type=\"checkbox\" data-src=\"0:1\"></div>\n\n- [ ] a‸\n", [letter("b")], "<div data-src=\"0:1\" data-run contenteditable=\"true\"><input type=\"checkbox\" data-src=\"0:1\"></div>\n\n- [ ] ab‸\n"),
    ("right after an image", "a ![i](x.png)‸ b\n", [letter("X")], "a ![i](x.png)X‸ b\n"),
    ("backspace an image", "a ![i](x.png)‸ b\n", [Step.key("\u{7F}", 51, [])], "a ‸ b\n"),
]


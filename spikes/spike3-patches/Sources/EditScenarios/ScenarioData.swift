import EditCore

let typing: [Scenario] = [
    .init("type mid-word", "hel‸lo world\n", [.type("X")], "helX‸lo world\n", "p[helXlo world]"),
    .init("type at text-run end before bold", "foo‸**bar**\n", [.type("x")], "foox‸**bar**\n", "p[foox<b>bar</b>]"),
    .init("type at start inside bold", "foo**‸bar**\n", [.type("x")], "foo**x‸bar**\n", "p[foo<b>xbar</b>]"),
    .init("type at end inside bold", "foo**bar‸** baz\n", [.type("x")], "foo**barx‸** baz\n", "p[foo<b>barx</b> baz]"),
    .init("type a phrase with spaces", "a‸\n", [.type(" big cat")], "a big cat‸\n", "p[a big cat]"),
    .init("type asterisk stays literal", "x *a‸\n", [.type("*")], "x *a\\*‸\n", "p[x *a*]"),
    .init("type # and space at paragraph start stays literal", "‸foo\n", [.type("# ")], "\\# ‸foo\n", "p[# foo]"),
    .init("type - and space at paragraph start stays literal", "‸foo\n", [.type("- ")], "\\- ‸foo\n", "p[- foo]"),
    .init("type 1. and space at paragraph start stays literal", "‸foo\n", [.type("1. ")], "1\\. ‸foo\n", "p[1. foo]"),
    .init("type emoji inside CJK bold", "**中‸文**\n", [.type("🎉")], "**中🎉‸文**\n", "p[<b>中🎉文</b>]"),
    .init("type after emoji", "👍🏽‸ ok\n", [.type("a")], "👍🏽a‸ ok\n", "p[👍🏽a ok]"),
    .init("type backticks that would pair", "a ` b‸\n", [.type("`")], "a \\` b\\`‸\n", "p[a ` b`]"),
]

let deleting: [Scenario] = [
    .init("backspace mid-word", "hel‸lo\n", [.backspace], "he‸lo\n", "p[helo]"),
    .init("forward delete mid-word", "he‸llo\n", [.forwardDelete], "he‸lo\n", "p[helo]"),
    .init("delete across inline boundary into bold", "fo⟦o **ba⟧r** baz\n", [.deleteSelection], "fo‸**r** baz\n", "p[fo<b>r</b> baz]"),
    .init("delete across inline boundary out of bold", "**fo⟦o** ba⟧r\n", [.deleteSelection], "**fo‸**r\n", "p[<b>fo</b>r]"),
    .init("delete across two marks", "*a⟦b* mid **c⟧d**\n", [.deleteSelection], "*a‸***d**\n", "p[<i>a</i><b>d</b>]"),
    .init("delete a whole word", "hello ⟦world⟧ again\n", [.deleteSelection], "hello ‸ again\n", "p[hello  again]"),
    .init("delete all of a bold run", "a **⟦b⟧** c\n", [.deleteSelection], "a ‸ c\n", "p[a  c]"),
    .init("deleting leaves bold starting with a space", "**⟦b⟧ c**\n", [.deleteSelection], "**‸c**\n", "p[<b>c</b>]"),
    .init("backspace a skin-tone emoji", "a👍🏽‸b\n", [.backspace], "a‸b\n", "p[ab]"),
    .init("backspace a ZWJ family emoji", "a👨‍👩‍👧‍👦‸b\n", [.backspace], "a‸b\n", "p[ab]"),
    .init("backspace a flag", "🇯🇵‸x\n", [.backspace], "‸x\n", "p[x]"),
    .init("backspace CJK", "中文‸字\n", [.backspace], "中‸字\n", "p[中字]"),
    .init("backspace a combining mark cluster", "e\u{301}‸x\n", [.backspace], "‸x\n", "p[x]"),
    .init("delete across paragraphs", "ab⟦c\n\nd⟧ef\n", [.deleteSelection], "ab‸ef\n", "p[abef]"),
    .init("delete across paragraphs keeps bold tail", "ab⟦c\n\n**d⟧e**\n", [.deleteSelection], "ab‸**e**\n", "p[ab<b>e</b>]"),
    .init("delete a paragraph's only text", "one\n\n⟦two⟧\n\nthree\n", [.deleteSelection], "one\n\n‸\n\nthree\n", "p[one],p[three]"),
    .init("merge paragraph into previous", "a\n\n‸b\n", [.backspace], "a‸b\n", "p[ab]"),
    .init("merge paragraph into heading", "# a\n\n‸b\n", [.backspace], "# a‸b\n", "h1[ab]"),
    .init("merge paragraph into list", "- a\n\n‸b\n", [.backspace], "- a‸b\n", "ul[li[p[ab]]]"),
    .init("forward delete merges next paragraph", "a‸\n\nb\n", [.forwardDelete], "a‸b\n", "p[ab]"),
    .init("backspace at document start does nothing", "‸a\n", [.backspace], "‸a\n", "p[a]"),
    .init("backspace after code block keeps the boundary", "```\nx\n```\n\n‸a\n", [.backspace], "```\nx\n```\n\n‸a\n", "code()[x],p[a]"),
    .init("backspace deletes a rule above", "a\n\n---\n\n‸b\n", [.backspace], "a\n\n‸b\n", "p[a],p[b]"),
]

let enter: [Scenario] = [
    .init("enter in a paragraph", "foo‸bar\n", [.enter], "foo\n\n‸bar\n", "p[foo],p[bar]"),
    .init("enter inside bold splits the mark", "**foo‸bar**\n", [.enter], "**foo**\n\n**‸bar**\n", "p[<b>foo</b>],p[<b>bar</b>]"),
    .init("enter drops the space at the split", "foo ‸bar\n", [.enter], "foo\n\n‸bar\n", "p[foo],p[bar]"),
    .init("enter at paragraph end then type", "foo‸\n", [.enter, .type("bar")], "foo\n\nbar‸\n", "p[foo],p[bar]"),
    .init("enter between paragraphs then type", "foo‸\n\nnext\n", [.enter, .type("mid")], "foo\n\nmid‸\n\nnext\n", "p[foo],p[mid],p[next]"),
    .init("enter with a selection", "fo⟦o b⟧ar\n", [.enter], "fo\n\n‸ar\n", "p[fo],p[ar]"),
    .init("enter in a heading", "# fo‸o\n", [.enter], "# fo\n\n‸o\n", "h1[fo],p[o]"),
    .init("enter at heading end then type", "# foo‸\n\nnext\n", [.enter, .type("x")], "# foo\n\nx‸\n\nnext\n", "h1[foo],p[x],p[next]"),
    .init("shift-enter makes a hard break", "foo‸bar\n", [.shiftEnter], "foo\\\n‸bar\n", "p[foo⇩bar]"),
]

let lists: [Scenario] = [
    .init("enter in a list item", "- a‸b\n- c\n", [.enter], "- a\n- ‸b\n- c\n", "ul[li[p[a]],li[p[b]],li[p[c]]]"),
    .init("enter at list item end", "- a‸\n- b\n", [.enter], "- a\n- ‸\n- b\n", "ul[li[p[a]],li[],li[p[b]]]"),
    .init("enter at item end then type", "- a‸\n- b\n", [.enter, .type("new")], "- a\n- new‸\n- b\n", "ul[li[p[a]],li[p[new]],li[p[b]]]"),
    .init("enter keeps the star marker", "* a‸\n", [.enter], "* a\n* ‸\n", "ul[li[p[a]],li[]]"),
    .init("enter on empty last item leaves the list", "- a\n- ‸\n", [.enter], "- a\n\n‸\n", "ul[li[p[a]]]"),
    .init("leave a list then type", "- a\n- ‸\n", [.enter, .type("b")], "- a\n\nb‸\n", "ul[li[p[a]]],p[b]"),
    .init("enter on empty nested item outdents", "- a\n  - b\n  - ‸\n", [.enter], "- a\n  - b\n- ‸\n", "ul[li[p[a],ul[li[p[b]]]],li[]]"),
    .init("enter in ordered list renumbers", "1. a‸\n2. b\n3. c\n", [.enter], "1. a\n2. ‸\n3. b\n4. c\n", "ol1[li[p[a]],li[],li[p[b]],li[p[c]]]"),
    .init("enter in all-ones list keeps ones", "1. a‸\n1. b\n", [.enter], "1. a\n1. ‸\n1. b\n", "ol1[li[p[a]],li[],li[p[b]]]"),
    .init("enter in a task item", "- [x] a‸\n", [.enter], "- [x] a\n- [ ] ‸\n", "ul[li(x)[p[a]],li( )[]]"),
    .init("enter in a loose list", "- a‸\n\n- b\n", [.enter], "- a\n\n- ‸\n\n- b\n", "ul[li[p[a]],li[],li[p[b]]]"),
    .init("enter with nested children below", "- a‸b\n  - sub\n", [.enter], "- a\n- ‸b\n  - sub\n", "ul[li[p[a]],li[p[b],ul[li[p[sub]]]]]"),
    .init("backspace at middle item start", "- a\n- ‸b\n- c\n", [.backspace], "- a\n\n‸b\n\n- c\n", "ul[li[p[a]]],p[b],ul[li[p[c]]]"),
    .init("backspace at first item start", "- ‸a\n- b\n", [.backspace], "‸a\n\n- b\n", "p[a],ul[li[p[b]]]"),
    .init("backspace at last item start", "- a\n- ‸b\n", [.backspace], "- a\n\n‸b\n", "ul[li[p[a]]],p[b]"),
    .init("backspace at nested item start outdents", "- a\n  - ‸b\n", [.backspace], "- a\n- ‸b\n", "ul[li[p[a]],li[p[b]]]"),
    .init("backspace on empty item", "- a\n- ‸\n", [.backspace], "- a\n\n‸\n", "ul[li[p[a]]]"),
    .init("click a task checkbox", "- [ ] a‸\n- [x] b\n", [.checkbox], "- [x] a‸\n- [x] b\n", "ul[li(x)[p[a]],li(x)[p[b]]]"),
    .init("click a checked box", "- [ ] a\n- [x] b‸\n", [.checkbox], "- [ ] a\n- [ ] b‸\n", "ul[li( )[p[a]],li( )[p[b]]]"),
]

let quotes: [Scenario] = [
    .init("enter in a block quote", "> a‸b\n", [.enter], "> a\n>\n> ‸b\n", "q[p[a],p[b]]"),
    .init("enter twice leaves a quote", "> a‸\n", [.enter, .enter], "> a\n\n‸\n", "q[p[a]]"),
    .init("enter at quote end then type", "> a‸\n", [.enter, .type("b")], "> a\n>\n> b‸\n", "q[p[a],p[b]]"),
    .init("backspace at quote start", "> ‸a\n", [.backspace], "‸a\n", "p[a]"),
    .init("backspace at multi-line quote start", "> ‸a\n> b\n", [.backspace], "‸a\nb\n", "p[a⏎b]"),
    .init("backspace at first of two quote paragraphs", "> ‸a\n>\n> b\n", [.backspace], "‸a\n\n> b\n", "p[a],q[p[b]]"),
    .init("merge within a quote", "> a\n>\n> ‸b\n", [.backspace], "> a‸b\n", "q[p[ab]]"),
    .init("type on a continuation line in a quote", "> a\n> b‸ c\n", [.type("x")], "> a\n> bx‸ c\n", "q[p[a⏎bx c]]"),
    .init("enter in a list inside a quote", "> - a‸\n> - b\n", [.enter], "> - a\n> - ‸\n> - b\n", "q[ul[li[p[a]],li[],li[p[b]]]]"),
    .init("paragraph split inside a list item in a quote", "> - a\n>\n>   b‸c\n", [.enter], "> - a\n>\n>   b\n>\n>   ‸c\n", "q[ul[li[p[a],p[b],p[c]]]]"),
]

let formatting: [Scenario] = [
    .init("bold a partial selection", "he⟦llo wo⟧rld\n", [.toggle(.strong)], "he**llo wo‸**rld\n", "p[he<b>llo wo</b>rld]"),
    .init("bold trims selection whitespace", "a⟦ b ⟧c\n", [.toggle(.strong)], "a **b‸** c\n", "p[a <b>b</b> c]"),
    .init("unbold the middle of a run", "**he⟦ll⟧o**\n", [.toggle(.strong)], "**he**ll‸**o**\n", "p[<b>he</b>ll<b>o</b>]"),
    .init("unbold the whole run", "a **⟦b⟧** c\n", [.toggle(.strong)], "a b‸ c\n", "p[a b c]"),
    .init("bold next to an existing run", "**a** ⟦b⟧ c\n", [.toggle(.strong)], "**a** **b‸** c\n", "p[<b>a</b> <b>b</b> c]"),
    .init("bold across an italic run", "⟦a *b* c⟧\n", [.toggle(.strong)], "**a *b* c‸**\n", "p[<b>a <i>b</i> c</b>]"),
    .init("bold overlapping italic", "*a ⟦b* c⟧\n", [.toggle(.strong)], "*a **b*** **c‸**\n", "p[<i>a <b>b</b></i> <b>c</b>]"),
    .init("italic a word", "⟦foo⟧ bar\n", [.toggle(.em)], "*foo‸* bar\n", "p[<i>foo</i> bar]"),
    .init("italic follows the file's underscore style", "_x_ and ⟦foo⟧\n", [.toggle(.em)], "_x_ and _foo‸_\n", "p[<i>x</i> and <i>foo</i>]"),
    .init("underscore style uses stars mid-word", "_x_ and fo⟦o⟧d\n", [.toggle(.em)], "_x_ and fo*o‸*d\n", "p[<i>x</i> and fo<i>o</i>d]"),
    .init("inline code a word", "a ⟦foo⟧ b\n", [.toggle(.code)], "a `foo‸` b\n", "p[a <c>foo</c> b]"),
    .init("remove inline code", "a `⟦foo⟧` b\n", [.toggle(.code)], "a foo‸ b\n", "p[a foo b]"),
    .init("inline code around a star", "a ⟦2*3⟧ b\n", [.toggle(.code)], "a `2*3‸` b\n", "p[a <c>2*3</c> b]"),
    .init("remove code keeps a star literal", "a *b* `⟦c*⟧` d\n", [.toggle(.code)], "a *b* c*‸ d\n", "p[a <i>b</i> c* d]"),
    .init("inline code around a backtick", "a ⟦x`y⟧ b\n", [.toggle(.code)], "a ``x`y‸`` b\n", "p[a <c>x`y</c> b]"),
    .init("strikethrough a word", "a ⟦b⟧ c\n", [.toggle(.strike)], "a ~~b‸~~ c\n", "p[a <s>b</s> c]"),
    .init("bold CJK partial", "中⟦文字⟧符\n", [.toggle(.strong)], "中**文字‸**符\n", "p[中<b>文字</b>符]"),
    .init("bold around emoji", "a ⟦👍🏽 ok⟧ b\n", [.toggle(.strong)], "a **👍🏽 ok‸** b\n", "p[a <b>👍🏽 ok</b> b]"),
]

let headings: [Scenario] = [
    .init("paragraph to heading", "fo‸o\n", [.heading(2)], "## fo‸o\n", "h2[foo]"),
    .init("change heading level", "# fo‸o\n", [.heading(3)], "### fo‸o\n", "h3[foo]"),
    .init("heading to paragraph", "## fo‸o\n", [.heading(0)], "fo‸o\n", "p[foo]"),
    .init("backspace at heading start", "# ‸foo\n", [.backspace], "‸foo\n", "p[foo]"),
    .init("setext level swap", "fo‸o\n---\n", [.heading(1)], "fo‸o\n===\n", "h1[foo]"),
    .init("setext to ATX", "fo‸o\n===\n", [.heading(3)], "### fo‸o\n", "h3[foo]"),
    .init("type in a setext heading", "fo‸o\n===\n\nnext\n", [.type("x")], "fox‸o\n===\n\nnext\n", "h1[foxo],p[next]"),
    .init("type in an ATX heading with closing hashes", "## fo‸o ##\n", [.type("x")], "## fox‸o ##\n", "h2[foxo]"),
    .init("multi-line paragraph to heading", "a‸\nb\n", [.heading(1)], "# a‸ b\n", "h1[a b]"),
]

let pasting: [Scenario] = [
    .init("paste plain text", "a‸b\n", [.pastePlain("hello")], "ahello‸b\n", "p[ahellob]"),
    .init("paste plain with specials stays literal", "a‸\n", [.pastePlain(" *x* [y](z)")], "a \\*x\\* \\[y\\](z)‸\n", "p[a *x* [y](z)]"),
    .init("paste plain over a selection", "a⟦bc⟧d\n", [.pastePlain("X")], "aX‸d\n", "p[aXd]"),
    .init("paste plain with one newline", "a‸b\n", [.pastePlain("x\ny")], "ax\ny‸b\n", "p[ax⏎yb]"),
    .init("paste plain paragraphs", "a‸b\n", [.pastePlain("x\n\ny")], "ax\n\ny‸b\n", "p[ax],p[yb]"),
    .init("paste paragraphs inside a quote", "> a‸b\n", [.pastePlain("x\n\ny")], "> ax\n>\n> y‸b\n", "q[p[ax],p[yb]]"),
    .init("paste CRLF text into an LF file", "a‸\n", [.pastePlain("x\r\ny")], "ax\ny‸\n", "p[ax⏎y]"),
    .init("paste plain into bold", "**a‸b**\n", [.pastePlain("x")], "**ax‸b**\n", "p[<b>axb</b>]"),
    .init("paste rich inline", "a‸b\n", [.pasteRich([PasteBlock(.paragraph, [PasteRun("x", marks: ["strong"]), PasteRun(" y"), PasteRun("z", marks: ["em"])])])],
          "a**x** y*z‸*b\n", "p[a<b>x</b> y<i>z</i>b]"),
    .init("paste rich link", "a ‸b\n", [.pasteRich([PasteBlock(.paragraph, [PasteRun("site", href: "https://e.com")])])],
          "a [site‸](https://e.com)b\n", "p[a <a=https://e.com>site</a>b]"),
    .init("paste rich blocks", "ab‸\n\nnext\n", [.pasteRich([PasteBlock(.heading(2), [PasteRun("T")]), PasteBlock(.bullet, [PasteRun("x")]), PasteBlock(.bullet, [PasteRun("y", marks: ["code"])])])],
          "ab\n\n## T\n\n- x\n- `y`‸\n\nnext\n", "p[ab],h2[T],ul[li[p[x]],li[p[<c>y</c>]]],p[next]"),
    .init("paste rich splits a paragraph", "a‸b\n", [.pasteRich([PasteBlock(.paragraph, [PasteRun("x")]), PasteBlock(.paragraph, [PasteRun("y")])])],
          "ax\n\ny‸\n\nb\n", "p[ax],p[y],p[b]"),
]

let tableSource = "| a | b |\n|---|---|\n| c | d |\n"
let tables: [Scenario] = [
    .init("type in a cell", "| a‸ | b |\n|---|---|\n| c | d |\n", [.type("x")], "| ax‸ | b |\n|---|---|\n| c | d |\n", "t[r[c[ax],c[b]],r[c[c],c[d]]]"),
    .init("type a pipe in a cell", "| a |\n|---|\n| b‸ |\n", [.type("|")], "| a |\n|---|\n| b\\|‸ |\n", "t[r[c[a]],r[c[b|]]]"),
    .init("type after an escaped pipe", "| a |\n|---|\n| b\\|c‸ |\n", [.type("x")], "| a |\n|---|\n| b\\|cx‸ |\n", "t[r[c[a]],r[c[b|cx]]]"),
    .init("backspace at cell start does nothing", "| a | ‸b |\n|---|---|\n", [.backspace], "| a | ‸b |\n|---|---|\n", "t[r[c[a],c[b]]]"),
    .init("enter in a cell does nothing", "| a‸ | b |\n|---|---|\n", [.enter], "| a‸ | b |\n|---|---|\n", "t[r[c[a],c[b]]]"),
    .init("delete a cell's text", "| a | b |\n|---|---|\n| ⟦c⟧ | d |\n", [.deleteSelection], "| a | b |\n|---|---|\n| ‸ | d |\n", "t[r[c[a],c[b]],r[c[],c[d]]]"),
    .init("type in an empty cell", "| a | b |\n|---|---|\n| ‸ | d |\n", [.type("x")], "| a | b |\n|---|---|\n| x‸ | d |\n", "t[r[c[a],c[b]],r[c[x],c[d]]]"),
    .init("emoji in a cell", "| 中‸ |\n|---|\n", [.type("🎉")], "| 中🎉‸ |\n|---|\n", "t[r[c[中🎉]]]"),
    .init("bold in a cell", "| ⟦a⟧ | b |\n|---|---|\n", [.toggle(.strong)], "| **a‸** | b |\n|---|---|\n", "t[r[c[<b>a</b>],c[b]]]"),
    .init("deletion across cells is refused", "| ⟦a | b⟧ |\n|---|---|\n", [.deleteSelection], "| ‸a | b |\n|---|---|\n", "t[r[c[a],c[b]]]"),
]

let preservation: [Scenario] = [
    .init("CRLF: type keeps endings", "a‸b\r\n\r\nc\r\n", [.type("x")], "ax‸b\r\n\r\nc\r\n", "p[axb],p[c]"),
    .init("CRLF: enter writes CRLF", "a‸b\r\n\r\nc\r\n", [.enter], "a\r\n\r\n‸b\r\n\r\nc\r\n", "p[a],p[b],p[c]"),
    .init("CRLF: enter in list", "- a‸\r\n- b\r\n", [.enter], "- a\r\n- ‸\r\n- b\r\n", "ul[li[p[a]],li[],li[p[b]]]"),
    .init("CRLF: quote split", "> a‸b\r\n", [.enter], "> a\r\n>\r\n> ‸b\r\n", "q[p[a],p[b]]"),
    .init("entities and escapes stay as written", "&amp; \\*x\\* &copy; a‸\n", [.type("b")], "&amp; \\*x\\* &copy; ab‸\n", "p[& *x* © ab]"),
    .init("underscore emphasis stays underscore", "__a__ _b_ c‸\n", [.type("d")], "__a__ _b_ cd‸\n", "p[<b>a</b> <i>b</i> cd]"),
    .init("delimiter order stays", "**_a_** _**b**_ c‸\n", [.type("d")], "**_a_** _**b**_ cd‸\n", "p[<b><i>a</i></b> <i><b>b</b></i> cd]"),
    .init("two-space hard break stays", "a  \nb‸\n", [.type("c")], "a  \nbc‸\n", "p[a⇩bc]"),
    .init("reference link stays", "[a][r]‸ b\n\n[r]: /u\n", [.type("x")], "[a][r]x‸ b\n\n[r]: /u\n", "p[<a=/u>a</a>x b]"),
    .init("autolink stays", "<https://e.com> a‸\n", [.type("b")], "<https://e.com> ab‸\n", "p[<a=https://e.com>https://e.com</a> ab]"),
    .init("image stays", "![alt](i.png \"t\") a‸\n", [.type("b")], "![alt](i.png \"t\") ab‸\n", "p[▣ ab]"),
    .init("inline HTML stays", "a <kbd>b</kbd> c‸\n", [.type("d")], "a <kbd>b</kbd> cd‸\n", "p[a ▣b▣ cd]"),
    .init("other blocks stay untouched", "*   a\n\n1) b\n\nx‸\n\n***\n", [.type("y")], "*   a\n\n1) b\n\nxy‸\n\n***\n", "ul[li[p[a]]],ol1[li[p[b]]],p[xy],hr"),
    .init("BOM-less mixed endings stay", "a\nb‸\r\nc\r", [.type("x")], "a\nbx‸\r\nc\r", "p[a⏎bx⏎c]"),
    .init("trailing spaces stay until typed past", "ab  ‸\n", [.type("c")], "ab  c‸\n", "p[ab  c]"),
    .init("no trailing newline", "ab‸", [.type("c")], "abc‸", "p[abc]"),
]

/// The inline position bugs from `spikes/spike1-ranges/REPORT.md`.
let spike1Bugs: [Scenario] = [
    .init("after a backslash hard break", "a\\\nb *c*\nd *e‸*\n", [.type("x")], "a\\\nb *c*\nd *ex‸*\n", "p[a⇩b <i>c</i>⏎d <i>ex</i>]"),
    .init("after a link split across lines", "[a](\nhttp://x) *b*\nc *d‸*\n", [.type("x")], "[a](\nhttp://x) *b*\nc *dx‸*\n", "p[<a=http://x>a</a> <i>b</i>⏎c <i>dx</i>]"),
    .init("lazy continuation in a list", "- item\nlazy *em‸*\n", [.type("x")], "- item\nlazy *emx‸*\n", "ul[li[p[item⏎lazy <i>emx</i>]]]"),
    .init("lazy continuation in a quote", "> quote\nlazy `co‸de`\n", [.type("x")], "> quote\nlazy `cox‸de`\n", "q[p[quote⏎lazy <c>coxde</c>]]"),
    .init("extra-indented continuation", "plain\n   `co‸de` end\n", [.type("x")], "plain\n   `cox‸de` end\n", "p[plain⏎<c>coxde</c> end]"),
    .init("after an escaped pipe in a cell", "| a |\n|---|\n| x\\|y *z‸* |\n", [.type("q")], "| a |\n|---|\n| x\\|y *zq‸* |\n", "t[r[c[a]],r[c[x|y <i>zq</i>]]]"),
    .init("setext heading right before text", "Foo\n---\nb‸ar\n", [.type("x")], "Foo\n---\nbx‸ar\n", "h2[Foo],p[bxar]"),
]

let codeBlocks: [Scenario] = [
    .init("type in a code block", "```\nfo‸o\n```\n", [.type("x")], "```\nfox‸o\n```\n", "code()[foxo]"),
    .init("enter in a code block", "```\nfo‸o\n```\n", [.enter], "```\nfo\n‸o\n```\n", "code()[fo⏎o]"),
    .init("code stays literal", "```\n*a*‸\n```\n", [.type("*")], "```\n*a**‸\n```\n", "code()[*a**]"),
    .init("enter in code inside a list", "- x\n\n  ```\n  a‸\n  ```\n", [.enter], "- x\n\n  ```\n  a\n  ‸\n  ```\n", "ul[li[p[x],code()[a⏎]]]"),
    .init("backspace in a code block", "```\nab‸\n```\n", [.backspace], "```\na‸\n```\n", "code()[a]"),
]

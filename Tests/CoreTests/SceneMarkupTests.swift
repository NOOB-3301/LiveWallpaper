import XCTest
@testable import Core

final class SceneMarkupTests: XCTestCase {
    func testPlainTextIsUnchanged() {
        let markup = SceneMarkup("音频条audio bar")
        XCTAssertEqual(markup.plainText, "音频条audio bar")
        XCTAssertEqual(markup.blocks.count, 1)
        XCTAssertFalse(markup.isDecorationOnly)
    }

    func testEmptyMarkupIsDecorationOnly() {
        let markup = SceneMarkup("  <br/><hr/>  ")
        XCTAssertTrue(markup.plainText.isEmpty)
        XCTAssertTrue(markup.isDecorationOnly)
    }

    func testBoldBigAndLineBreaks() throws {
        let markup = SceneMarkup("<b>● 镜头大小<br/>Lens size")
        XCTAssertEqual(markup.plainText, "● 镜头大小\nLens size")
        XCTAssertEqual(markup.blocks.count, 2)
        let first = try line(markup.blocks[0])
        let second = try line(markup.blocks[1])
        XCTAssertEqual(first.text, "● 镜头大小")
        XCTAssertTrue(first.runs[0].isBold)
        XCTAssertEqual(second.text, "Lens size")
        XCTAssertTrue(second.runs[0].isBold, "an unclosed <b> keeps applying, as in a browser")
    }

    func testCenterLinkAndUnclosedBig() throws {
        let markup = SceneMarkup(#"<center><big><b>我的个人主页<br/><a href='https://space.bilibili.com/425570450'>bai22331</a><big></p>"#)
        XCTAssertEqual(markup.plainText, "我的个人主页\nbai22331")
        XCTAssertEqual(markup.blocks.count, 2)
        let first = try line(markup.blocks[0])
        let second = try line(markup.blocks[1])
        XCTAssertEqual(first.alignment, .center)
        XCTAssertEqual(second.alignment, .center)
        XCTAssertTrue(first.runs[0].isBold)
        XCTAssertEqual(first.runs[0].scale, 1.2, accuracy: 0.0001)
        XCTAssertEqual(second.runs.last?.link?.absoluteString, "https://space.bilibili.com/425570450")
    }

    func testFontColorAndRule() throws {
        let markup = SceneMarkup(#"<font color=#fcffb1><hr><big><b>🔘双击语音 拉至0取消"#)
        XCTAssertEqual(markup.plainText, "🔘双击语音 拉至0取消")
        guard case .rule = markup.blocks[0] else { return XCTFail("leading <hr> should stay as a rule") }
        let line = try line(markup.blocks[1])
        XCTAssertTrue(line.runs[0].isBold)
        XCTAssertEqual(line.runs[0].scale, 1.2, accuracy: 0.0001)
        let color = try XCTUnwrap(line.runs[0].color)
        XCTAssertEqual(color.red, 0xfc / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.green, 0xff / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blue, 0xb1 / 255.0, accuracy: 0.001)
    }

    func testImageAttributesAndSeparators() throws {
        let separator = SceneMarkup(#"<img src="http://photogz.photo.store.qq.com/psc?/V12" width="2000" height="1">"#)
        XCTAssertTrue(separator.isDecorationOnly)
        guard case .image(let ruleImage) = separator.blocks.first else { return XCTFail("missing image") }
        XCTAssertTrue(ruleImage.isSeparator)
        XCTAssertEqual(ruleImage.url.host, "photogz.photo.store.qq.com")
        XCTAssertEqual(ruleImage.width, 2000)
        XCTAssertEqual(ruleImage.height, 1)

        let qr = SceneMarkup(#"<img src="https://example.com/qr.webp" width="200" height="200">"#)
        guard case .image(let qrImage) = qr.blocks.first else { return XCTFail("missing image") }
        XCTAssertFalse(qrImage.isSeparator)
        XCTAssertEqual(qrImage.width, 200)
        XCTAssertEqual(qrImage.height, 200)
    }

    func testEscapedQuotesInImageTagRecover() throws {
        let markup = SceneMarkup(#"<img src="https://example.com/a.png\" width=\"200\" height=\"200\">"#)
        guard case .image(let image) = markup.blocks.first else { return XCTFail("escaped quotes should parse") }
        XCTAssertEqual(image.url.absoluteString, "https://example.com/a.png")
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 200)
    }

    func testNonWebImagesAreDropped() {
        let markup = SceneMarkup(#"<img src="file:///C:/Users/me/desktop/a.png" width="200" height="200">"#)
        XCTAssertTrue(markup.blocks.isEmpty)
    }

    func testEntities() {
        let markup = SceneMarkup("A&nbsp;B &amp; C &lt;3 &#65;&#x42;")
        XCTAssertEqual(markup.plainText, "A\u{00A0}B & C <3 AB")
    }

    func testMalformedMarkupStaysAsText() {
        XCTAssertEqual(SceneMarkup("< When < b> x").plainText, "< When < b> x")
        XCTAssertEqual(SceneMarkup("5 < 6 > 4").plainText, "5 < 6 > 4")
        XCTAssertEqual(SceneMarkup("x </small> y").plainText, "x y")
    }

    func testUnclosedTagAppliesToRemainder() throws {
        let markup = SceneMarkup("<b>bold")
        XCTAssertEqual(markup.plainText, "bold")
        XCTAssertTrue(try line(markup.blocks[0]).runs[0].isBold)
    }

    func testUnknownTagsAreDroppedButTextKept() {
        XCTAssertEqual(SceneMarkup("<span>hi</span>").plainText, "hi")
    }

    func testLeadingAndTrailingBreaksAreTrimmed() {
        XCTAssertEqual(SceneMarkup("<br/><br/>text<br/><br/>").plainText, "text")
    }

    func testNestedBigScalesAndCloses() throws {
        let markup = SceneMarkup("<big><big>a</big>b")
        let runs = try line(markup.blocks[0]).runs
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].text, "a")
        XCTAssertEqual(runs[0].scale, 1.44, accuracy: 0.0001)
        XCTAssertEqual(runs[1].text, "b")
        XCTAssertEqual(runs[1].scale, 1.2, accuracy: 0.0001)
    }

    func testUnsafeLinkIsNotClickableButTextIsKept() throws {
        let markup = SceneMarkup(#"<a href="javascript:alert(1)">click</a>"#)
        XCTAssertEqual(markup.plainText, "click")
        XCTAssertNil(try line(markup.blocks[0]).runs[0].link)
    }

    func testParagraphTagsBreakLines() {
        let markup = SceneMarkup("<p>one</p><p>two</p>")
        XCTAssertEqual(markup.plainText, "one\ntwo")
        XCTAssertEqual(markup.blocks.count, 2)
    }

    func testOverlappingTagsRecoverLikeABrowser() throws {
        // <i> is still open when </b> arrives: the bold ends with its tag, the italic carries on.
        let markup = SceneMarkup("<b><i>x</b>y")
        let runs = try line(markup.blocks[0]).runs
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs[0].isBold)
        XCTAssertTrue(runs[0].isItalic)
        XCTAssertFalse(runs[1].isBold)
        XCTAssertTrue(runs[1].isItalic)
    }

    func testCommentsAndStylesAreHidden() {
        XCTAssertEqual(SceneMarkup("<!-- c --><style>b{color:red}</style><b>t</b>").plainText, "t")
    }

    func testScreenshotRowsStayReadable() {
        let rows = [
            #"<br><big><b>● 组件随音频感应变化大小（拉至0取消）"#,
            #"<hr><big><b>● 音频条1<br/>Audio Bar 1"#,
            #"<b>媒体组件大小<br>Media component size"#,
        ]
        for row in rows {
            let markup = SceneMarkup(row)
            XCTAssertFalse(markup.plainText.contains("<"), "raw tag left in \(markup.plainText)")
            XCTAssertFalse(markup.plainText.contains("&lt;"), "raw entity left in \(markup.plainText)")
        }
        XCTAssertEqual(SceneMarkup(#"<hr><big><b>● 音频条1<br/>Audio Bar 1"#).plainText, "● 音频条1\nAudio Bar 1")
    }

    private func line(_ block: SceneMarkup.Block) throws -> SceneMarkup.Line {
        guard case .line(let line) = block else {
            throw XCTSkip("not a line block")
        }
        return line
    }
}

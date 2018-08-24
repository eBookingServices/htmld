module html.dom;


import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.experimental.allocator;
import std.range;
import std.string;
import std.typecons;

import html.parser;
import html.utils;


alias HTMLString = const(char)[];
static if(__VERSION__ >= 2079){
	alias IAllocator = RCIAllocator;
}

enum DOMCreateOptions {
	None = 0,
	DecodeEntities  		= 1 << 0,

	ValidateClosed			= 1 << 10,
	ValidateSelfClosing		= 1 << 11,
	ValidateDuplicateAttr	= 1 << 12,
	ValidateBasic			= ValidateClosed | ValidateSelfClosing | ValidateDuplicateAttr,
	ValidateAll				= ValidateBasic,

	Default = DecodeEntities,
}


enum ValidationError : size_t {
	None,
	MismatchingClose = 1,
	MissingClose,
	StrayClose,
	SelfClosingNonVoidElement,
	DuplicateAttr,
}


alias ValidationErrorCallable = void delegate(ValidationError, HTMLString, HTMLString);


alias onlyElements = a => a.isElementNode;


private struct ChildrenForward(NodeType, alias Condition = null) {
	this(NodeType first) {
		curr_ = cast(Node)first;
		static if (!is(typeof(Condition) == typeof(null))) {
			while (curr_ && !Condition(curr_))
				curr_ = curr_.next_;
		}
	}

	bool empty() const {
		return (curr_ is null);
	}

	NodeType front() const {
		return cast(NodeType)curr_;
	}

	void popFront() {
		curr_ = curr_.next_;

		static if (!is(typeof(Condition) == typeof(null))) {
			while (curr_) {
				if (Condition(curr_))
					break;
				curr_ = curr_.next_;
			}
		}
	}

	private Node curr_;
}


private struct AncestorsForward(NodeType, alias Condition = null) {
	this(NodeType first) {
		curr_ = cast(Node)first;
		static if (!is(typeof(Condition) == typeof(null))) {
			while (curr_ && !Condition(curr_))
				curr_ = curr_.parent_;
		}
	}

	bool empty() const {
		return (curr_ is null);
	}

	NodeType front() const {
		return cast(NodeType)curr_;
	}

	void popFront() {
		curr_ = curr_.parent_;

		static if (!is(typeof(Condition) == typeof(null))) {
			while (curr_) {
				if (Condition(curr_))
					break;
				curr_ = curr_.parent_;
			}
		}
	}

	private Node curr_;
}


private struct DescendantsForward(NodeType, alias Condition = null) {
	this(NodeType top) {
		if (top is null)
			return;
		curr_ = cast(Node)top.firstChild_; // top itself is excluded
		top_ = cast(Node)top;
		static if (!is(typeof(Condition) == typeof(null))) {
			if (!Condition(curr_))
				popFront;
		}
	}

	bool empty() const {
		return (curr_ is null);
	}

	NodeType front() const {
		return cast(NodeType)curr_;
	}

	void popFront() {
		while (curr_) {
			if (curr_.firstChild_) {
				curr_ = curr_.firstChild_;
			} else if (curr_ !is top_) {
				auto next = curr_.next_;
				if (!next) {
					Node parent = curr_.parent_;
					while (parent) {
						if (parent !is top_) {
							if (parent.next_) {
								next = parent.next_;
								break;
							}
							parent = parent.parent_;
						} else {
							next = null;
							break;
						}
					}
				}

				curr_ = next;
				if (!curr_)
					break;
			} else {
				curr_ = null;
				break;
			}

			static if (is(typeof(Condition) == typeof(null))) {
				break;
			} else {
				if (Condition(curr_))
					break;
			}
		}
	}

	private Node curr_;
	private Node top_;
}

unittest {
	const doc = createDocument(`<div id=a><div id=b></div><div id=c><div id=e></div><div id=f><div id=h></div></div><div id=g></div></div><div id=d></div></div>`);
	assert(DescendantsForward!(const(Node))(doc.root).count() == 8);
	auto fs = DescendantsForward!(const(Node), x => x.attr("id") == "f")(doc.root);
	assert(fs.count() == 1);
	assert(fs.front().attr("id") == "f");
	auto hs = DescendantsForward!(const(Node), x => x.attr("id") == "h")(fs.front());
	assert(hs.count() == 1);
	assert(hs.front().attr("id") == "h");
	auto divs = DescendantsForward!(const(Node))(fs.front());
	assert(divs.count() == 1);
}

unittest {
	// multiple top-level nodes
	const doc = createDocument(`<div id="left"></div><div id="mid"></div><div id="right"></div>`);
	assert(DescendantsForward!(const Node)(doc.root).count() == 3);
	assert(doc.nodes.count() == 3);
}

unittest {
	const doc = createDocument(``);
	assert(DescendantsForward!(const Node)(doc.root).empty);
	assert(doc.nodes.empty);
}


private struct QuerySelectorMatcher(NodeType, Nodes) if (isInputRange!Nodes) {
	this(Selector selector, Nodes nodes) {
		selector_ = selector;
		nodes_ = nodes;

		while (!nodes_.empty()) {
			auto node = nodes_.front();
			if (node.isElementNode && selector_.matches(node))
				break;

			nodes_.popFront();
		}
	}

	bool empty() const {
		return nodes_.empty();
	}

	NodeType front() const {
		return cast(NodeType)nodes_.front();
	}

	void popFront() {
		nodes_.popFront();
		while (!nodes_.empty()) {
			auto node = nodes_.front();
			if (node.isElementNode && selector_.matches(node))
				break;

			nodes_.popFront();
		}
	}

	private Nodes nodes_;
	private Selector selector_;
}


enum NodeTypes : ubyte {
	Text = 0,
	Element,
	Comment,
	CDATA,
	Declaration,
	ProcessingInstruction,
}


class Node {
	@disable this();

	private this(HTMLString tag, Document document, size_t flags) {
		flags_ = flags;
		tag_ = tag;

		parent_ = null;
		firstChild_ = null;
		lastChild_ = null;

		prev_ = null;
		next_ = null;

		document_ = document;
	}

	auto opIndex(HTMLString name) const {
		return attr(name);
	}

	void opIndexAssign(T)(T value, HTMLString name) {
		attr(name, value.to!string);
	}

	@property auto id() const {
		return attr("id");
	}

	@property void id(T)(T value) {
		attr("id", value.to!string);
	}

	@property auto type() const {
		return (flags_ & TypeMask) >> TypeShift;
	}

	@property auto tag() const {
		return isElementNode ? tag_ : null;
	}

	@property auto comment() const {
		return isCommentNode ? tag_ : null;
	}

	@property auto cdata() const {
		return isCDATANode ? tag_ : null;
	}

	@property auto declaration() const {
		return isDeclarationNode ? tag_ : null;
	}

	@property auto processingInstruction() const {
		return isProcessingInstructionNode ? tag_ : null;
	}

	void text(Appender)(ref Appender app) const {
		if (isTextNode) {
			app.put(tag_);
		} else {
			Node child = cast(Node)firstChild_;
			while (child) {
				child.text(app);
				child = child.next_;
			}
		}
	}

	@property auto text() const {
		if (isTextNode) {
			return tag_;
		} else {
			Appender!HTMLString app;
			text(app);
			return app.data;
		}
	}

	@property void text(HTMLString text) {
		if (isTextNode) {
			tag_ = text;
		} else {
			destroyChildren();
			appendText(text);
		}
	}

	@property void attr(HTMLString name, HTMLString value) {
		assert(isElementNode, "cannot set attributes of non-element nodes");

		attrs_[name] = value;
	}

	@property HTMLString attr(HTMLString name) const {
		if (auto pattr = name in attrs_)
			return *pattr;
		return null;
	}

	bool hasAttr(HTMLString name) const {
		return (name in attrs_) != null;
	}

	void removeAttr(HTMLString name) {
		attrs_.remove(name);
	}

	@property void html(size_t Options = DOMCreateOptions.Default)(HTMLString html) {
		assert(isElementNode, "cannot add html to non-element nodes");

		enum parserOptions = ((Options & DOMCreateOptions.DecodeEntities) ? ParserOptions.DecodeEntities : 0);

		destroyChildren();

		auto builder = DOMBuilder!(Document, Options)(document_, this);
		parseHTML!(typeof(builder), parserOptions)(html, builder);
	}

	@property auto html() const {
		Appender!HTMLString app;
		innerHTML(app);
		return app.data;
	}

	@property auto compactHTML() const {
		Appender!HTMLString app;
		compactInnerHTML(app);
		return app.data;
	}

	@property auto outerHTML() const {
		Appender!HTMLString app;
		outerHTML(app);
		return app.data;
	}

	@property auto compactOuterHTML() const {
		Appender!HTMLString app;
		compactOuterHTML(app);
		return app.data;
	}

	void prependChild(Node node) {
		assert(document_ == node.document_);
		assert(isElementNode, "cannot prepend to non-element nodes");

		if (node.parent_)
			node.detach();
		node.parent_ = this;
		if (firstChild_) {
			assert(!firstChild_.prev_);
			firstChild_.prev_ = node;
			node.next_ = firstChild_;
			firstChild_ = node;
		} else {
			assert(!lastChild_);
			firstChild_ = node;
			lastChild_ = node;
		}
	}

	void appendChild(Node node) {
		assert(document_ == node.document_);
		assert(isElementNode, "cannot append to non-element nodes");

		if (node.parent_)
			node.detach();
		node.parent_ = this;
		if (lastChild_) {
			assert(!lastChild_.next_);
			lastChild_.next_ = node;
			node.prev_ = lastChild_;
			lastChild_ = node;
		} else {
			assert(!firstChild_);
			firstChild_ = node;
			lastChild_ = node;
		}
	}

	void removeChild(Node node) {
		assert(node.parent_ is this);
		node.detach();
	}

	void destroyChildren() {
		auto child = firstChild_;
		while (child) {
			auto next = child.next_;
			child.destroy();
			child = next;
		}

		firstChild_ = null;
		lastChild_ = null;
	}

	void prependText(HTMLString text) {
		auto node = document_.createTextNode(text);
		if (firstChild_) {
			assert(firstChild_.prev_ is null);
			firstChild_.prev_ = node;
			node.next_ = firstChild_;
			firstChild_ = node;
		} else {
			assert(lastChild_ is null);
			firstChild_ = node;
			lastChild_ = node;
		}
		node.parent_ = this;
	}

	void appendText(HTMLString text) {
		auto node = document_.createTextNode(text);
		if (lastChild_) {
			assert(lastChild_.next_ is null);
			lastChild_.next_ = node;
			node.prev_ = lastChild_;
			lastChild_ = node;
		} else {
			assert(firstChild_ is null);
			firstChild_ = node;
			lastChild_ = node;
		}
		node.parent_ = this;
	}

	void insertBefore(Node node) {
		assert(document_ is node.document_);

		parent_ = node.parent_;
		prev_ = node.prev_;
		next_ = node;
		node.prev_ = this;

		if (prev_)
			prev_.next_ = this;
		else if (parent_)
			parent_.firstChild_ = this;
	}

	void insertAfter(Node node) {
		assert(document_ is node.document_);

		parent_ = node.parent_;
		prev_ = node;
		next_ = node.next_;
		node.next_ = this;

		if (next_)
			next_.prev_ = this;
		else if (parent_)
			parent_.lastChild_ = this;
	}

	void detach() {
		if (parent_) {
			if (parent_.firstChild_ is this) {
				parent_.firstChild_ = next_;
				if (next_) {
					next_.prev_ = null;
					next_ = null;
				} else {
					parent_.lastChild_ = null;
				}

				assert(prev_ is null);
			} else if (parent_.lastChild_ is this) {
				parent_.lastChild_ = prev_;
				assert(prev_);
				assert(next_ is null);
				prev_.next_ = null;
				prev_ = null;
			} else {
				assert(prev_);

				prev_.next_ = next_;
				if (next_) {
					next_.prev_ = prev_;
					next_ = null;
				}
				prev_ = null;
			}
			parent_ = null;
		}
	}

	package void detachFast() {
		if (parent_) {
			if (parent_.firstChild_ is this) {
				parent_.firstChild_ = next_;
				if (next_) {
					next_.prev_ = null;
				} else {
					parent_.lastChild_ = null;
				}

				assert(prev_ is null);
			} else if (parent_.lastChild_ is this) {
				parent_.lastChild_ = prev_;
				assert(prev_);
				assert(next_ is null);
				prev_.next_ = null;
			} else {
				assert(prev_);

				prev_.next_ = next_;
				if (next_) {
					next_.prev_ = prev_;
				}
			}
		}
	}

	void destroy() {
		detachFast();
		destroyChildren();
		document_.destroyNode(this);
	}

	void innerHTML(Appender)(ref Appender app) const {
		auto child = cast(Node)firstChild_;
		while (child) {
			child.outerHTML(app);
			child = child.next_;
		}
	}

	void compactInnerHTML(Appender)(ref Appender app) const {
		auto child = cast(Node)firstChild_;
		while (child) {
			child.compactOuterHTML(app);
			child = child.next_;
		}
	}

	void outerHTML(Appender)(ref Appender app) const {
		final switch (type) with (NodeTypes) {
		case Element:
			app.put('<');
			app.put(tag_);

			foreach(HTMLString attr, HTMLString value; attrs_) {
				app.put(' ');
				app.put(attr);

				if (value.length) {
					if (value.requiresQuotes) {
						app.put("=\"");
						app.writeQuotesEscaped(value);
						app.put("\"");
					} else {
						app.put('=');
						app.put(value);
					}
				}
			}

			if (isVoidElement) {
				app.put(">");
			} else {
				app.put('>');
				switch (tagHashOf(tag_))
				{
				case tagHashOf("script"):
				case tagHashOf("style"):
					if (firstChild_)
						app.put(firstChild_.tag_);
					break;
				default:
					innerHTML(app);
					break;
				}
				app.put("</");
				app.put(tag_);
				app.put('>');
			}
			break;
		case Text:
			app.put(tag_);
			break;
		case Comment:
			app.put("<!--");
			app.put(tag_);
			app.put("-->");
			break;
		case CDATA:
			app.put("<![CDATA[");
			app.put(tag_);
			app.put("]]>");
			break;
		case Declaration:
			app.put("<!");
			app.put(tag_);
			app.put(">");
			break;
		case ProcessingInstruction:
			app.put("<?");
			app.put(tag_);
			app.put(">");
			break;
		}
	}

	void compactOuterHTML(Appender)(ref Appender app) const {
		final switch (type) with (NodeTypes) {
		case Element:
			app.put('<');
			app.put(tag_);

			foreach (HTMLString attr, HTMLString value; attrs_) {
				app.put(' ');
				app.put(attr);

				if (value.length) {
					if (value.requiresQuotes) {
						app.put("=\"");
						app.writeQuotesEscaped(value);
						app.put("\"");
					} else {
						app.put('=');
						app.put(value);
					}
				}
			}

			if (isVoidElement) {
				app.put(">");
			} else {
				app.put('>');
				switch (tagHashOf(tag_)) {
				case tagHashOf("script"):
				case tagHashOf("style"):
					if (firstChild_)
						app.put(firstChild_.tag_.strip());
					break;
				default:
					compactInnerHTML(app);
					break;
				}
				app.put("</");
				app.put(tag_);
				app.put('>');
			}
			break;
		case Text:
			auto ptr = tag_.ptr;
			const end = ptr + tag_.length;

			if (tag_.isAllWhite()) {
				size_t aroundCount;
				Node[2] around;

				around.ptr[aroundCount] = cast(Node)prev_;
				if (!around.ptr[aroundCount])
					around.ptr[aroundCount] = cast(Node)parent_;
				if (around.ptr[aroundCount])
					++aroundCount;
				around.ptr[aroundCount] = cast(Node)next_;
				if (!around.ptr[aroundCount])
					around.ptr[aroundCount] = cast(Node)parent_;
				if (around.ptr[aroundCount] && (!aroundCount || (around.ptr[aroundCount] !is around.ptr[aroundCount - 1])))
					++aroundCount;

				auto tagsMatch = true;
				Laround: foreach (i; 0..aroundCount) {
					if (around.ptr[i].isElementNode) {
						switch (tagHashOf(around.ptr[i].tag_)) {
						case tagHashOf("html"):
						case tagHashOf("head"):
						case tagHashOf("title"):
						case tagHashOf("meta"):
						case tagHashOf("link"):
						case tagHashOf("script"):
						case tagHashOf("noscript"):
						case tagHashOf("style"):
						case tagHashOf("body"):
						case tagHashOf("br"):
						case tagHashOf("p"):
						case tagHashOf("div"):
						case tagHashOf("center"):
						case tagHashOf("dl"):
						case tagHashOf("form"):
						case tagHashOf("hr"):
						case tagHashOf("ol"):
						case tagHashOf("ul"):
						case tagHashOf("table"):
						case tagHashOf("tbody"):
						case tagHashOf("tr"):
						case tagHashOf("td"):
						case tagHashOf("th"):
						case tagHashOf("tfoot"):
						case tagHashOf("thead"):
							continue;
						default:
							tagsMatch = false;
							break Laround;
						}
					}
				}

				if (!tagsMatch && (ptr != end))
					app.put(*ptr);
			} else {
				auto space = false;
				while (ptr != end) {
					auto ch = *ptr++;
					if (isWhite(ch)) {
						if (space)
							continue;
						space = true;
					} else {
						space = false;
					}
					app.put(ch);
				}
			}
			break;
		case Comment:
			auto stripped = tag_.strip();
			if (!stripped.empty() && (tag_.front() == '[')) {
				app.put("<!--");
				app.put(tag_);
				app.put("-->");
			}
			break;
		case CDATA:
			app.put("<![CDATA[");
			app.put(tag_);
			app.put("]]>");
			break;
		case Declaration:
			app.put("<!");
			app.put(tag_);
			app.put(">");
			break;
		case ProcessingInstruction:
			app.put("<?");
			app.put(tag_);
			app.put(">");
			break;
		}
	}

	void toString(Appender)(ref Appender app) const {
		final switch (type) with (NodeTypes) {
		case Element:
			app.put('<');
			app.put(tag_);

			foreach(HTMLString attr, HTMLString value; attrs_) {
				app.put(' ');
				app.put(attr);

				if (value.length) {
					app.put("=\"");
					writeHTMLEscaped!(Yes.escapeQuotes)(app, value);
					app.put("\"");
				}
			}
			if (isVoidElement) {
				app.put(">");
			} else {
				app.put("/>");
			}
			break;
		case Text:
			writeHTMLEscaped!(No.escapeQuotes)(app, tag_);
			break;
		case Comment:
			app.put("<!--");
			app.put(tag_);
			app.put("-->");
			break;
		case CDATA:
			app.put("<![CDATA[");
			app.put(tag_);
			app.put("]]>");
			break;
		case Declaration:
			app.put("<!");
			app.put(tag_);
			app.put(">");
			break;
		case ProcessingInstruction:
			app.put("<?");
			app.put(tag_);
			app.put(">");
			break;
		}
	}

	override string toString() const {
		Appender!HTMLString app;
		toString(app);
		return cast(string)app.data;
	}

	@property auto parent() const {
		return parent_;
	}

	@property auto parent() {
		return parent_;
	}

	@property auto firstChild() const {
		return firstChild_;
	}

	@property auto firstChild() {
		return firstChild_;
	}

	@property auto lastChild() const {
		return lastChild_;
	}

	@property auto lastChild() {
		return lastChild_;
	}

	@property auto previousSibling() const {
		return prev_;
	}

	@property auto previousSibling() {
		return prev_;
	}

	@property auto nextSibling() const {
		return next_;
	}

	@property auto nextSibling() {
		return next_;
	}

	@property auto children() const {
		return ChildrenForward!(const(Node))(firstChild_);
	}

	@property auto children() {
		return ChildrenForward!Node(firstChild_);
	}

	@property auto attrs() const {
		return attrs_;
	}

	@property auto attrs() {
		return attrs_;
	}

	auto find(HTMLString selector) const {
		return document_.querySelectorAll(selector, this);
	}

	auto find(HTMLString selector) {
		return document_.querySelectorAll(selector, this);
	}

	auto find(Selector selector) const {
		return document_.querySelectorAll(selector, this);
	}

	auto find(Selector selector) {
		return document_.querySelectorAll(selector, this);
	}

	auto closest(HTMLString selector) const {
		auto rules = Selector.parse(selector);
		return closest(rules);
	}

	Node closest(HTMLString selector) {
		auto rules = Selector.parse(selector);
		return closest(rules);
	}

	auto closest(Selector selector) const {
		if (selector.matches(this))
			return this;

		foreach (node; ancestors) {
			if (selector.matches(node))
				return node;
		}
		return null;
	}

	Node closest(Selector selector) {
		if (selector.matches(this))
			return this;

		foreach (node; ancestors) {
			if (selector.matches(node))
				return node;
		}
		return null;
	}

	@property auto ancestors() const {
		return AncestorsForward!(const(Node))(parent_);
	}

	@property auto ancestors() {
		return AncestorsForward!Node(parent_);
	}

	@property auto descendants() const {
		return DescendantsForward!(const(Node))(this);
	}

	@property auto descendants() {
		return DescendantsForward!Node(this);
	}

	@property isSelfClosing() const {
		return (flags_ & Flags.SelfClosing) != 0;
	}

	@property isVoidElement() const {
		if (!isElementNode)
			return false;
		switch (tagHashOf(tag_)) {
		case tagHashOf("area"):
		case tagHashOf("base"):
		case tagHashOf("basefont"):
		case tagHashOf("br"):
		case tagHashOf("col"):
		case tagHashOf("hr"):
		case tagHashOf("img"):
		case tagHashOf("input"):
		case tagHashOf("isindex"):
		case tagHashOf("link"):
		case tagHashOf("meta"):
		case tagHashOf("param"):
		case tagHashOf("wbr"):
			return true;
		default:
			return false;
		}
	}

	@property isElementNode() const {
		return type == NodeTypes.Element;
	}

	@property isTextNode() const {
		return type == NodeTypes.Text;
	}

	@property isCommentNode() const {
		return type == NodeTypes.Comment;
	}

	@property isCDATANode() const {
		return type == NodeTypes.CDATA;
	}

	@property isDeclarationNode() const {
		return type == NodeTypes.Declaration;
	}

	@property isProcessingInstructionNode() const {
		return type == NodeTypes.ProcessingInstruction;
	}

	Node clone(Document document) const {
		auto node = document.allocNode(tag_, flags_);

		foreach (HTMLString attr, HTMLString value; attrs_)
			node.attrs_[attr] = value;

		Node current = cast(Node)firstChild_;

		while (current !is null) {
			auto newChild = current.clone(document);
			node.appendChild(newChild);
			current = current.next_;
		}
		return node;
	}

	Node clone() const {
		return document_.cloneNode(this);
	}

package:
	enum TypeMask	= 0x7UL;
	enum TypeShift	= 0UL;
	enum FlagsBit	= TypeMask + 1;
	enum Flags {
		SelfClosing = FlagsBit << 1,
	}

	size_t flags_;
	HTMLString tag_; // when Text flag is set, will contain the text itself
	HTMLString[HTMLString] attrs_;

	Node parent_;
	Node firstChild_;
	Node lastChild_;

	// siblings
	Node prev_;
	Node next_;

	Document document_;
}


auto createDocument(size_t Options = DOMCreateOptions.Default)(HTMLString source, IAllocator alloc = theAllocator) {
	enum parserOptions = ((Options & DOMCreateOptions.DecodeEntities) ? ParserOptions.DecodeEntities : 0);
	static assert((Options & DOMCreateOptions.ValidateAll) == 0, "requested validation with no error callable");

	auto document = createDocument(alloc);
	auto builder = DOMBuilder!(Document, Options)(document);

	parseHTML!(typeof(builder), parserOptions)(source, builder);
	return document;
}


auto createDocument(size_t Options = DOMCreateOptions.Default | DOMCreateOptions.ValidateAll)(HTMLString source, ValidationErrorCallable errorCallable, IAllocator alloc = theAllocator) {
	enum parserOptions = ((Options & DOMCreateOptions.DecodeEntities) ? ParserOptions.DecodeEntities : 0);
	static assert((Options & DOMCreateOptions.ValidateAll) != 0, "error callable but validation not requested");

	auto document = createDocument(alloc);
	auto builder = DOMBuilder!(Document, Options)(document, errorCallable);

	parseHTML!(typeof(builder), parserOptions)(source, builder);
	return document;
}


unittest {
	auto doc = createDocument("<html> <body> \n\r\f\t </body> </html>");
	assert(doc.root.compactOuterHTML == "<root><html><body></body></html></root>");
	doc = createDocument("<html> <body> <div> <p>  <a>  </a> </p> </div> </body> </html>");
	assert(doc.root.compactOuterHTML == "<root><html><body><div><p> <a> </a> </p></div></body></html></root>");
}

unittest {
	auto doc = createDocument(`<html><body>&nbsp;</body></html>`);
	assert(doc.root.outerHTML == "<root><html><body>\&nbsp;</body></html></root>");
	doc = createDocument!(DOMCreateOptions.None)(`<html><body>&nbsp;</body></html>`);
	assert(doc.root.outerHTML == `<root><html><body>&nbsp;</body></html></root>`);
	doc = createDocument(`<script>&nbsp;</script>`);
	assert(doc.root.outerHTML == `<root><script>&nbsp;</script></root>`, doc.root.outerHTML);
	doc = createDocument(`<style>&nbsp;</style>`);
	assert(doc.root.outerHTML == `<root><style>&nbsp;</style></root>`, doc.root.outerHTML);
}

unittest {
	const doc = createDocument(`<html><body><div title='"Тест&apos;"'>"К"ириллица</div></body></html>`);
	assert(doc.root.html == `<html><body><div title="&#34;Тест'&#34;">"К"ириллица</div></body></html>`);
}

unittest {
	// void elements should not be self-closed
	auto doc = createDocument(`<area><base><br><col>`);
	assert(doc.root.outerHTML == `<root><area><base><br><col></root>`, doc.root.outerHTML);
	doc = createDocument(`<svg /><math /><svg></svg>`);
	assert(doc.root.outerHTML == `<root><svg></svg><math></math><svg></svg></root>`, doc.root.outerHTML);
	doc = createDocument(`<br /><div />`);
	assert(doc.root.outerHTML == `<root><br><div></div></root>`, doc.root.outerHTML);
}

// toString prints elements with content as <tag attr="value"/>
unittest {
	// self-closed element w/o content
	auto doc = createDocument(`<svg />`);
	assert(doc.root.firstChild.toString == `<svg/>`, doc.root.firstChild.toString);
	// elements w/ content
	doc = createDocument(`<svg></svg>`);
	assert(doc.root.firstChild.toString == `<svg/>`, doc.root.firstChild.toString);
	doc = createDocument(`<div class="mydiv"></div>`);
	assert(doc.root.firstChild.toString == `<div class="mydiv"/>`, doc.root.firstChild.toString);
	// void element
	doc = createDocument(`<br>`);
	assert(doc.root.firstChild.toString == `<br>`, doc.root.firstChild.toString);
	// "invalid" self-closed void element
	doc = createDocument(`<br />`);
	assert(doc.root.firstChild.toString == `<br>`, doc.root.firstChild.toString);
}

unittest {
	const doc = createDocument(`<html><body><div>&nbsp;</div></body></html>`);
	assert(doc.root.find("html").front.outerHTML == "<html><body><div>\&nbsp;</div></body></html>");
	assert(doc.root.find("html").front.find("div").front.outerHTML == "<div>\&nbsp;</div>");
	assert(doc.root.find("body").front.outerHTML == "<body><div>\&nbsp;</div></body>");
	assert(doc.root.find("body").front.closest("body").outerHTML == "<body><div>\&nbsp;</div></body>"); // closest() tests self
	assert(doc.root.find("body").front.closest("html").outerHTML == "<html><body><div>\&nbsp;</div></body></html>");
}

unittest {
	const doc = createDocument(`<html><body><![CDATA[test]]></body></html>`);
	assert(doc.root.firstChild.firstChild.firstChild.isCDATANode);
	assert(doc.root.html == `<html><body><![CDATA[test]]></body></html>`);
}


static auto createDocument(IAllocator alloc = theAllocator) {
	auto document = new Document(alloc);
	document.root(document.createElement("root"));
	return document;
}


class Document {
	private this(IAllocator alloc) {
		alloc_ = alloc;
	}

	auto createElement(HTMLString tagName, Node parent = null) {
		auto node = allocNode(tagName, NodeTypes.Element << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return node;
	}

	auto createTextNode(HTMLString text, Node parent = null) {
		auto node = allocNode(text, NodeTypes.Text << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return node;
	}

	auto createCommentNode(HTMLString comment, Node parent = null) {
		auto node = allocNode(comment, NodeTypes.Comment << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return node;
	}

	auto createCDATANode(HTMLString cdata, Node parent = null) {
		auto node = allocNode(cdata, NodeTypes.CDATA << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return node;
	}

	auto createDeclarationNode(HTMLString data, Node parent = null) {
		auto node = allocNode(data, NodeTypes.Declaration << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return node;
	}

	auto createProcessingInstructionNode(HTMLString data, Node parent = null) {
		auto node = allocNode(data, NodeTypes.ProcessingInstruction << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return node;
	}

	Node cloneNode(const(Node) other) const {
		return other.clone(cast(Document)this);
	}

	Document clone(IAllocator alloc = theAllocator) {
		Document other = new Document(alloc);
		other.root(other.cloneNode(this.root_));
		return other;
	}

	@property auto root() {
		return root_;
	}

	@property auto root() const {
		return root_;
	}

	@property void root(Node root) {
		if (root && (root.document_.alloc_ != alloc_))
			alloc_ = root.document_.alloc_;
		root_ = root;
	}

	@property auto nodes() const {
		return DescendantsForward!(const(Node))(root_);
	}

	@property auto nodes() {
		return DescendantsForward!Node(root_);
	}

	@property auto elements() const {
		return DescendantsForward!(const(Node), onlyElements)(root_);
	}

	@property auto elements() {
		return DescendantsForward!(Node, onlyElements)(root_);
	}

	@property auto elementsByTagName(HTMLString tag) const {
		return DescendantsForward!(const(Node), (a) { return a.isElementNode && (a.tag.equalsCI(tag)); })(root_);
	}

	@property auto elementsByTagName(HTMLString tag) {
		return DescendantsForward!(Node, (a) { return a.isElementNode && (a.tag.equalsCI(tag)); })(root_);
	}

	const(Node) querySelector(HTMLString selector, Node context = null) const {
		auto rules = Selector.parse(selector);
		return querySelector(rules, context);
	}

	Node querySelector(HTMLString selector, Node context = null) {
		auto rules = Selector.parse(selector);
		return querySelector(rules, context);
	}

	const(Node) querySelector(Selector selector, const(Node) context = null) const {
		auto top = context ? context : root_;

		foreach(node; DescendantsForward!(const(Node), onlyElements)(top)) {
			if (selector.matches(node))
				return node;
		}
		return null;
	}

	Node querySelector(Selector selector, Node context = null) {
		auto top = context ? context : root_;

		foreach(node; DescendantsForward!(Node, onlyElements)(top)) {
			if (selector.matches(node))
				return node;
		}
		return null;
	}

	alias QuerySelectorAllResult = QuerySelectorMatcher!(Node, DescendantsForward!Node);
	alias QuerySelectorAllConstResult = QuerySelectorMatcher!(const(Node), DescendantsForward!(const(Node)));

	QuerySelectorAllResult querySelectorAll(HTMLString selector, Node context = null) {
		auto rules = Selector.parse(selector);
		return querySelectorAll(rules, context);
	}

	QuerySelectorAllConstResult querySelectorAll(HTMLString selector, const(Node) context = null) const {
		auto rules = Selector.parse(selector);
		return querySelectorAll(rules, context);
	}

	QuerySelectorAllConstResult querySelectorAll(Selector selector, const(Node) context = null) const {
		auto top = context ? context : root_;
		return QuerySelectorMatcher!(const(Node), DescendantsForward!(const(Node)))(selector, DescendantsForward!(const(Node))(top));
	}

	QuerySelectorAllResult querySelectorAll(Selector selector, Node context = null) {
		auto top = context ? context : root_;
		return QuerySelectorMatcher!(Node, DescendantsForward!Node)(selector, DescendantsForward!Node(top));
	}

	void toString(Appender)(ref Appender app) const {
		root_.outerHTML(app);
	}

	override string toString() const {
		auto app = appender!HTMLString;
		root_.outerHTML(app);
		return cast(string)app.data;
	}

	auto allocNode()(HTMLString tag, size_t flags) {
		enum NodeSize = __traits(classInstanceSize, Node);
		auto ptr = cast(Node)alloc_.allocate(NodeSize).ptr;
		(cast(void*)ptr)[0..NodeSize] = typeid(Node).initializer[];
		ptr.__ctor(tag, this, flags);
		return ptr;
	}

	void destroyNode(Node node) {
		assert(node.firstChild_ is null);
		alloc_.dispose(node);
	}

private:
	Node root_;
	IAllocator alloc_;
}


unittest {
	const(char)[] src = `<parent attr=value><child></child>text</parent>`;
	auto doc = createDocument(src);
	assert(doc.root.html == src, doc.root.html);

	const(char)[] srcq = `<parent attr="v a l u e"><child></child>text</parent>`;
	auto docq = createDocument(srcq);
	assert(docq.root.html == srcq, docq.root.html);

	// basic cloning
	auto cloned = doc.cloneNode(doc.root);
	assert(cloned.html == src, cloned.html);
	assert(doc.root.html == src, cloned.html);

	assert(!cloned.find("child").empty);
	assert(!cloned.find("parent").empty);

	// clone mutation
	auto child = cloned.find("child").front.clone;
	child.attr("attr", "test");
	cloned.find("parent").front.appendChild(child);
	assert(cloned.html == `<parent attr=value><child></child>text<child attr=test></child></parent>`, cloned.html);
	assert(doc.root.html == src, doc.root.html);

	child.text = "text";
	assert(cloned.html == `<parent attr=value><child></child>text<child attr=test>text</child></parent>`, cloned.html);
	assert(doc.root.html == src, doc.root.html);

	// document cloning
	auto docc = doc.clone;
	assert(docc.root.html == doc.root.html, docc.root.html);
}


struct DOMBuilder(Document, size_t Options) {
	enum {
		Validate 				= (Options & DOMCreateOptions.ValidateAll) != 0,
		ValidateClosed 			= (Options & DOMCreateOptions.ValidateClosed) != 0,
		ValidateSelfClosing		= (Options & DOMCreateOptions.ValidateSelfClosing) != 0,
		ValidateDuplicateAttr	= (Options & DOMCreateOptions.ValidateDuplicateAttr) != 0,
	}

	static if (Validate) {
		this(Document document, ValidationErrorCallable errorCallable, Node parent = null) {
			document_ = document;
			element_ = parent ? parent : document.root;
			error_ = errorCallable;
		}
	} else {
		this(Document document, Node parent = null) {
			document_ = document;
			element_ = parent ? parent : document.root;
		}
	}

	void onText(HTMLString data) {
		if (data.ptr == (text_.ptr + text_.length)) {
			text_ = text_.ptr[0..text_.length + data.length];
		} else {
			text_ ~= data;
		}
	}

	void onSelfClosing() {
		if (element_.isVoidElement) {
			element_.flags_ |= Node.Flags.SelfClosing;
		} else {
			static if (ValidateSelfClosing) {
				error_(ValidationError.SelfClosingNonVoidElement, element_.tag_, null);
			}
		}
		element_ = element_.parent_;
	}

	void onOpenStart(HTMLString data) {
		if (!text_.empty) {
			element_.appendText(text_);
			text_.length = 0;
		}

		element_ = document_.createElement(data, element_);
	}

	void onOpenEnd(HTMLString data) {
		// void elements have neither content nor a closing tag, so
		// we're done w/ them on the end of the open tag
		if (element_.isVoidElement)
			element_ = element_.parent_;
	}

	void onClose(HTMLString data) {
		if (!text_.empty) {
			if (element_) {
				element_.appendText(text_);
				text_.length = 0;
			} else {
				document_.root.appendText(text_);
			}
		}

		if (element_) {
			assert(!element_.isTextNode);
			if (element_.tag.equalsCI(data)) {
				element_ = element_.parent_;
			} else {
				auto element = element_.parent_;
				while (element) {
					if (element.tag.equalsCI(data)) {
						static if (ValidateClosed) {
							error_(ValidationError.MismatchingClose, data, element_.tag);
						}
						element_ = element.parent_;
						break;
					}
					element = element.parent_;
				}
				static if (ValidateClosed) {
					if (!element)
						error_(ValidationError.StrayClose, data, null);
				}
			}
		} else {
			static if (ValidateClosed) {
				error_(ValidationError.StrayClose, data, null);
			}
		}
	}

	void onAttrName(HTMLString data) {
		attr_ = data;
		state_ = States.Attr;
	}

	void onAttrEnd() {
		if (!attr_.empty) {
			static if (ValidateDuplicateAttr) {
				if (attr_ in element_.attrs_)
					error_(ValidationError.DuplicateAttr, element_.tag_, attr_);
			}
			element_.attr(attr_, value_);
		}
		value_.length = 0;
		attr_.length = 0;
		state_ = States.Global;
	}

	void onAttrValue(HTMLString data) {
		if (data.ptr == (value_.ptr + value_.length)) {
			value_ = value_.ptr[0..value_.length + data.length];
		} else {
			value_ ~= data;
		}
	}

	void onComment(HTMLString data) {
		document_.createCommentNode(data, element_);
	}

	void onDeclaration(HTMLString data) {
		document_.createDeclarationNode(data, element_);
	}

	void onProcessingInstruction(HTMLString data) {
		document_.createProcessingInstructionNode(data, element_);
	}

	void onCDATA(HTMLString data) {
		document_.createCDATANode(data, element_);
	}

	void onDocumentEnd() {
		if (!text_.empty) {
			if (element_) {
				element_.appendText(text_);
				text_.length = 0;
			} else {
				document_.root.appendText(text_);
			}
		}

		static if (ValidateClosed) {
			while (element_ && element_ !is document_.root_) {
				error_(ValidationError.MissingClose, element_.tag, null);
				element_ = element_.parent_;
			}
		}
	}

	void onNamedEntity(HTMLString data) {
	}

	void onNumericEntity(HTMLString data) {
	}

	void onHexEntity(HTMLString data) {
	}

	void onEntity(HTMLString data, HTMLString decoded) {
		if (state_ == States.Global) {
			text_ ~= decoded;
		} else {
			value_ ~= decoded;
		}
	}

private:
	Document document_;
	Node element_;
	States state_;
	static if (Validate) {
		ValidationErrorCallable error_;
	}

	enum States {
		Global = 0,
		Attr,
	}

	HTMLString attr_;
	HTMLString value_;
	HTMLString text_;
}



unittest {
	static struct Error {
		ValidationError error;
		HTMLString tag;
		HTMLString related;
	}

	Error[] errors;
	void errorHandler(ValidationError error, HTMLString tag, HTMLString related) {
		errors ~= Error(error, tag, related);
	}

	errors.length = 0;
	auto doc = createDocument(`<div><div></div>`, &errorHandler);
	assert(errors == [Error(ValidationError.MissingClose, "div")]);

	errors.length = 0;
	doc = createDocument(`<div></div></div>`, &errorHandler);
	assert(errors == [Error(ValidationError.StrayClose, "div")]);

	errors.length = 0;
	doc = createDocument(`<span><div></span>`, &errorHandler);
	assert(errors == [Error(ValidationError.MismatchingClose, "span", "div")]);

	errors.length = 0;
	doc = createDocument(`<div />`, &errorHandler);
	assert(errors == [Error(ValidationError.SelfClosingNonVoidElement, "div")]);

	errors.length = 0;
	doc = createDocument(`<hr></hr>`, &errorHandler);
	assert(errors == [Error(ValidationError.StrayClose, "hr")]);

	errors.length = 0;
	doc = createDocument(`<span id=moo id=foo class=moo class=></span>`, &errorHandler);
	assert(errors == [Error(ValidationError.DuplicateAttr, "span", "id"), Error(ValidationError.DuplicateAttr, "span", "class")]);
}


private struct Rule {
	enum Flags : ushort {
		HasTag          = 1 << 0,
		HasAttr         = 1 << 1,
		HasPseudo       = 1 << 2,
		CaseSensitive   = 1 << 3,
		HasAny          = 1 << 4,
	}

	enum MatchType : ubyte {
		None = 0,
		Set,
		Exact,
		ContainWord,
		Contain,
		Begin,
		BeginHyphen,
		End,
	}

	enum Relation : ubyte {
		None = 0,
		Descendant,
		Child,
		DirectAdjacent,
		IndirectAdjacent,
	}

	bool matches(NodeType)(NodeType element) const {
		if (flags_ == 0)
			return false;

		if (flags_ & Flags.HasTag) {
			if (!tag_.equalsCI(element.tag))
				return false;
		}

		if (flags_ & Flags.HasAttr) {
			auto cs = (flags_ & Flags.CaseSensitive) != 0;
			final switch (match_) with (MatchType) {
			case None:
				break;
			case Set:
				if (element.attr(attr_) == null)
					return false;
				break;
			case Exact:
				if (value_.empty) return false;
				auto attr = element.attr(attr_);
				if (!attr || (cs ? (value_ != attr) : !value_.equalsCI(attr)))
					return false;
				break;
			case Contain:
				if (value_.empty) return false;
				auto attr = element.attr(attr_);
				if (!attr || ((attr.indexOf(value_, cs ? CaseSensitive.yes : CaseSensitive.no)) == -1))
					return false;
				break;
			case ContainWord:
				if (value_.empty) return false;
				auto attr = element.attr(attr_);
				if (!attr)
					return false;

				size_t start = 0;
				while (true) {
					auto index = attr.indexOf(value_, start, cs ? CaseSensitive.yes : CaseSensitive.no);
					if (index == -1)
						return false;
					if (index && !isWhite(attr[index - 1]))
						return false;
					if ((index + value_.length == attr.length) || isWhite(attr[index + value_.length]))
						break;
					start = index + 1;
				}
				break;
			case Begin:
				if (value_.empty) return false;
				auto attr = element.attr(attr_);
				if (!attr || ((attr.indexOf(value_, cs ? CaseSensitive.yes : CaseSensitive.no)) != 0))
					return false;
				break;
			case End:
				if (value_.empty) return false;
				auto attr = element.attr(attr_);
				if (!attr || ((attr.lastIndexOf(value_, cs ? CaseSensitive.yes : CaseSensitive.no)) != (attr.length - value_.length)))
					return false;
				break;
			case BeginHyphen:
				if (value_.empty) return false;
				auto attr = element.attr(attr_);
				if (!attr || ((attr.indexOf(value_, cs ? CaseSensitive.yes : CaseSensitive.no)) != 0) || ((attr.length > value_.length) && (attr[value_.length] != '-')))
					return false;
				break;
		   }
		}

		if (flags_ & Flags.HasPseudo) {
			switch (pseudo_) {
			case quickHashOf("checked"):
				if (!element.hasAttr("checked"))
					return false;
				break;

			case quickHashOf("enabled"):
				if (element.hasAttr("disabled"))
					return false;
				break;

			case quickHashOf("disabled"):
				if (!element.hasAttr("disabled"))
					return false;
				break;

			case quickHashOf("empty"):
				if (element.firstChild_)
					return false;
				break;

			case quickHashOf("optional"):
				if (element.hasAttr("required"))
					return false;
				break;

			case quickHashOf("read-only"):
				if (!element.hasAttr("readonly"))
					return false;
				break;

			case quickHashOf("read-write"):
				if (element.hasAttr("readonly"))
					return false;
				break;

			case quickHashOf("required"):
				if (!element.hasAttr("required"))
					return false;
				break;

			case quickHashOf("lang"):
				if (element.attr("lang") != pseudoArg_)
					return false;
				break;

			case quickHashOf("first-child"):
				if (!element.parent_ || (element.parent_.firstChild !is element))
					return false;
				break;

			case quickHashOf("last-child"):
				if (!element.parent_ || (element.parent_.lastChild !is element))
					return false;
				break;

			case quickHashOf("first-of-type"):
				Node sibling = element.previousSibling;
				while (sibling) {
					if (sibling.isElementNode && sibling.tag.equalsCI(element.tag))
						return false;
					sibling = sibling.previousSibling;
				}
				break;

			case quickHashOf("last-of-type"):
				auto sibling = element.nextSibling;
				while (sibling) {
					if (sibling.isElementNode && sibling.tag.equalsCI(element.tag))
						return false;
					sibling = sibling.nextSibling;
				}
				break;

			case quickHashOf("nth-child"):
				auto ith = 1;
				auto sibling = element.previousSibling;
				while (sibling) {
					if (ith > pseudoArgNum_)
						return false;
					if (sibling.isElementNode)
						++ith;
					sibling = sibling.previousSibling;
				}
				if (ith != pseudoArgNum_)
					return false;
				break;

			case quickHashOf("nth-last-child"):
				auto ith = 1;
				auto sibling = element.nextSibling;
				while (sibling) {
					if (ith > pseudoArgNum_)
						return false;
					if (sibling.isElementNode)
						++ith;
					sibling = sibling.nextSibling;
				}
				if (ith != pseudoArgNum_)
					return false;
				break;

			case quickHashOf("nth-of-type"):
				auto ith = 1;
				auto sibling = element.previousSibling;
				while (sibling) {
					if (ith > pseudoArgNum_)
						return false;
					if (sibling.isElementNode && sibling.tag.equalsCI(element.tag))
						++ith;
					sibling = sibling.previousSibling;
				}
				if (ith != pseudoArgNum_)
					return false;
				break;

			case quickHashOf("nth-last-of-type"):
				auto ith = 1;
				auto sibling = element.nextSibling;
				while (sibling) {
					if (ith > pseudoArgNum_)
						return false;
					if (sibling.isElementNode && sibling.tag.equalsCI(element.tag))
						++ith;
					sibling = sibling.nextSibling;
				}
				if (ith != pseudoArgNum_)
					return false;
				break;

			case quickHashOf("only-of-type"):
				auto sibling = element.previousSibling;
				while (sibling) {
					if (sibling.isElementNode && sibling.tag.equalsCI(element.tag))
						return false;
					sibling = sibling.previousSibling;
				}
				sibling = element.nextSibling;
				while (sibling) {
					if (sibling.isElementNode && sibling.tag.equalsCI(element.tag))
						return false;
					sibling = sibling.nextSibling;
				}
				break;

			case quickHashOf("only-child"):
				auto parent = element.parent_;
				if (parent is null)
					return false;
				Node sibling = parent.firstChild_;
				while (sibling) {
					if ((sibling !is element) && sibling.isElementNode)
						return false;
					sibling = sibling.next_;
				}
				break;

			default:
				break;
			}
		}

		return true;
	}

	@property Relation relation() const {
		return relation_;
	}

package:
	ushort flags_;
	MatchType match_;
	Relation relation_;
	size_t pseudo_;
	HTMLString tag_;
	HTMLString attr_;
	HTMLString value_;
	HTMLString pseudoArg_;
	uint pseudoArgNum_;
}


struct Selector {
	static Selector parse(HTMLString value) {
		enum ParserStates {
			Identifier = 0,
			PostIdentifier,
			Tag,
			Class,
			ID,
			AttrName,
			AttrOp,
			PreAttrValue,
			AttrValueDQ,
			AttrValueSQ,
			AttrValueNQ,
			PostAttrValue,
			Pseudo,
			PseudoArgs,
			Relation,
		}

		size_t ids;
		size_t tags;
		size_t classes;

		value = value.strip;
		auto source = uninitializedArray!(char[])(value.length + 1);
		source[0..value.length] = value;
		source[$-1] = ' '; // add a padding space to ease parsing

		auto selector = Selector(source);
		Rule[] rules;
		++rules.length;

		auto rule = &rules.back;

		auto ptr = source.ptr;
		auto end = source.ptr + source.length;
		auto start = ptr;

		ParserStates state = ParserStates.Identifier;

		while (ptr != end) {
			final switch (state) with (ParserStates) {
			case Identifier:
				if (*ptr == '#') {
					state = ID;
					start = ptr + 1;
				} else if (*ptr == '.') {
					state = Class;
					start = ptr + 1;
				} else if (*ptr == '[') {
					state = AttrName;
					start = ptr + 1;
				} else if (isAlpha(*ptr)) {
					state = Tag;
					start = ptr;
					continue;
				} else if (*ptr == '*') {
					rule.flags_ |= Rule.Flags.HasAny;
					state = PostIdentifier;
				} else if (*ptr == ':') {
					rule.flags_ |= Rule.Flags.HasAny;
					state = PostIdentifier;
					continue;
				}
				break;

			case PostIdentifier:
				switch (*ptr) {
				case '#':
					state = ID;
					start = ptr + 1;
					break;
				case '.':
					state = Class;
					start = ptr + 1;
					break;
				case '[':
					state = AttrName;
					start = ptr + 1;
					break;
				case ':':
					state = Pseudo;
					if ((ptr + 1 != end) && (*(ptr + 1) == ':'))
						++ptr;
					start = ptr + 1;
					break;
				default:
					state = Relation;
					continue;
				}
				break;

			case Tag:
				while ((ptr != end) && isAlphaNum(*ptr))
					++ptr;
				if (ptr == end)
					continue;

				rule.flags_ |= Rule.Flags.HasTag;
				rule.tag_ = start[0..ptr-start];
				++tags;

				state = PostIdentifier;
				continue;

			case Class:
				while ((ptr != end) && (isAlphaNum(*ptr) || (*ptr == '-') || (*ptr == '_')))
					++ptr;
				if (ptr == end)
					continue;

				rule.flags_ |= Rule.Flags.HasAttr;
				rule.match_ = Rule.MatchType.ContainWord;
				rule.attr_ = "class";
				rule.value_ = start[0..ptr-start];
				++classes;

				state = PostIdentifier;
				break;

			case ID:
				while ((ptr != end) && (isAlphaNum(*ptr) || (*ptr == '-') || (*ptr == '_')))
					++ptr;
				if (ptr == end)
					continue;

				rule.flags_ |= Rule.Flags.HasAttr;
				rule.match_ = Rule.MatchType.Exact;
				rule.attr_ = "id";
				rule.value_ = start[0..ptr-start];
				++ids;

				state = PostIdentifier;
				break;

			case AttrName:
				while ((ptr != end) && (isAlphaNum(*ptr) || (*ptr == '-') || (*ptr == '_')))
					++ptr;
				if (ptr == end)
					continue;

				rule.flags_ |= Rule.Flags.HasAttr;
				rule.flags_ |= Rule.Flags.CaseSensitive;
				rule.attr_ = start[0..ptr-start];
				++classes;

				state = AttrOp;
				continue;

			case AttrOp:
				while ((ptr != end) && (isWhite(*ptr)))
					++ptr;
				if (ptr == end)
					continue;

				switch (*ptr) {
				case ']':
					rule.match_ = Rule.MatchType.Set;
					state = PostIdentifier;
					break;
				case '=':
					rule.match_ = Rule.MatchType.Exact;
					state = PreAttrValue;
					break;
				default:
					if ((ptr + 1 != end) && (*(ptr + 1) == '=')) {
						switch (*ptr) {
						case '~':
							rule.match_ = Rule.MatchType.ContainWord;
							break;
						case '^':
							rule.match_ = Rule.MatchType.Begin;
							break;
						case '$':
							rule.match_ = Rule.MatchType.End;
							break;
						case '*':
							rule.match_ = Rule.MatchType.Contain;
							break;
						case '|':
							rule.match_ = Rule.MatchType.BeginHyphen;
							break;
						default:
							rule.flags_ = 0; // error
							ptr = end - 1;
							break;
						}

						state = PreAttrValue;
						++ptr;
					}
					break;
				}
				break;

			case PreAttrValue:
				while ((ptr != end) && isWhite(*ptr))
					++ptr;
				if (ptr == end)
					continue;

				if (*ptr == '\"') {
					state = AttrValueDQ;
					start = ptr + 1;
				} else if (*ptr == '\'') {
					state = AttrValueSQ;
					start = ptr + 1;
				} else {
					state = AttrValueNQ;
					start = ptr;
				}
				break;

			case AttrValueDQ:
				while ((ptr != end) && (*ptr != '\"'))
					++ptr;
				if (ptr == end)
					continue;

				rule.value_ = start[0..ptr-start];
				state = PostAttrValue;
				break;

			case AttrValueSQ:
				while ((ptr != end) && (*ptr != '\''))
					++ptr;
				if (ptr == end)
					continue;

				rule.value_ = start[0..ptr-start];
				state = PostAttrValue;
				break;

			case AttrValueNQ:
				while ((ptr != end) && !isWhite(*ptr) && (*ptr != ']'))
					++ptr;
				if (ptr == end)
					continue;

				rule.value_ = start[0..ptr-start];
				state = PostAttrValue;
				continue;

			case PostAttrValue:
				while ((ptr != end) && (*ptr != ']') && (*ptr != 'i'))
					++ptr;
				if (ptr == end)
					continue;

				if (*ptr == ']') {
					state = PostIdentifier;
				} else if (*ptr == 'i') {
					rule.flags_ &= ~cast(int)Rule.Flags.CaseSensitive;
				}
				break;

			case Pseudo:
				while ((ptr != end) && (isAlpha(*ptr) || (*ptr == '-')))
					++ptr;
				if (ptr == end)
					continue;

				rule.pseudo_ = quickHashOf(start[0..ptr-start]);
				rule.flags_ |= Rule.Flags.HasPseudo;
				++classes;
				if (*ptr != '(') {
					state = PostIdentifier;
					continue;
				} else {
					state = PseudoArgs;
					start = ptr + 1;
				}
				break;

			case PseudoArgs:
				while ((ptr != end) && (*ptr != ')'))
					++ptr;
				if (ptr == end)
					continue;

				rule.pseudoArg_ = start[0..ptr-start];
				if (isNumeric(rule.pseudoArg_))
					rule.pseudoArgNum_ = to!uint(rule.pseudoArg_);
				state = PostIdentifier;
				break;

			case Relation:
				while ((ptr != end) && isWhite(*ptr))
					++ptr;
				if (ptr == end)
					continue;

				++rules.length;
				rule = &rules.back;

				state = Identifier;
				switch (*ptr) {
				case '>':
					rule.relation_ = Rule.Relation.Child;
					break;
				case '+':
					rule.relation_ = Rule.Relation.DirectAdjacent;
					break;
				case '~':
					rule.relation_ = Rule.Relation.IndirectAdjacent;
					break;
				default:
					rule.relation_ = Rule.Relation.Descendant;
					continue;
				}
				break;
			}

			++ptr;
		}

		rules.reverse();
		selector.rules_ = rules;
		selector.specificity_ = (ids << 14) | (classes << 7) | (tags & 127);

		return selector;
	}

	bool matches(const(Node) node) {
		auto element = cast(Node)node;
		if (rules_.empty)
			return false;

		Rule.Relation relation = Rule.Relation.None;
		foreach(ref rule; rules_) {
			final switch (relation) with (Rule.Relation) {
			case None:
				if (!rule.matches(element))
					return false;
				break;
			case Descendant:
				auto parent = element.parent_;
				while (parent) {
					if (rule.matches(parent)) {
						element = parent;
						break;
					}
					parent = parent.parent_;
				}
				if (!parent)
					return false;

				break;
			case Child:
				auto parent = element.parent_;
				if (!parent || !rule.matches(parent))
					return false;
				element = parent;
				break;
			case DirectAdjacent:
				auto adjacent = element.previousSibling;
				if (!adjacent || !rule.matches(adjacent))
					return false;
				element = adjacent;
				break;
			case IndirectAdjacent:
				auto adjacent = element.previousSibling;
				while (adjacent) {
					if (rule.matches(adjacent)) {
						element = adjacent;
						break;
					}
					adjacent = adjacent.previousSibling;
				}
				if (!adjacent)
					return false;

				break;
			}

			relation = rule.relation;
		}

		return true;
	}

	@property size_t specificity() const {
		return specificity_;
	}

private:
	HTMLString source_;
	Rule[] rules_;
	size_t specificity_;
}

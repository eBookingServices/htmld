module html.dom;


import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.string;

import html.parser;
import html.alloc;
import html.utils;


alias HTMLString = const(char)[];

enum DOMCreateOptions {
	None = 0,
	DecodeEntities  = 1 << 0,

	Default = DecodeEntities,
}


enum OnlyElements = "(a) => { return a.isElementNode; }";


package NodeWrapper!T wrap(T)(T* node) {
	return NodeWrapper!T(node);
}

private struct ChildrenForward(NodeType, alias Condition = null) {
	this(NodeType* first) {
		static if (!is(typeof(Condition) == typeof(null))) {
			while (first && !Condition(first))
				first = first.next_;
		}
		curr_ = first;
	}

	bool empty() const {
		return (curr_ == null);
	}

	auto front() {
		return wrap(curr_);
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

	private NodeType* curr_;
}


// depth first traversal
private struct DescendantsDFForward(NodeType, alias Condition = null) {
	this(NodeType* first) {
		curr_ = first;
		top_ = (first && first.parent_) ? first.parent_ : null;
		static if (!is(typeof(Condition) == typeof(null))) {
			if (!Condition(first))
				popFront;
		}
	}

	bool empty() const {
		return (curr_ == null);
	}

	auto front() {
		return wrap(curr_);
	}

	void popFront() {
		while (curr_) {
			if (curr_.firstChild_) {
				curr_ = curr_.firstChild_;
			} else {
				NodeType* next = curr_.next_;
				if (!next) {
					NodeType* parent = curr_.parent_;
					while (parent && (top_ != parent)) {
						if (parent.next_)
							break;
						parent = parent.parent_;
					}
					if (parent)
						next = parent.next_;
				}

				curr_ = next;
				if (!curr_)
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

	private NodeType* curr_;
	private NodeType* top_;
}


private struct QuerySelectorAll(NodeType) {
	this(Selector selector, NodeType* context) {
		selector_ = selector;
		nodes_ = DescendantsDFForward!NodeType(context);
		popFront;
	}

	bool empty() const {
		return curr_ == null;
	}

	auto front() {
		return wrap(curr_);
	}

	void popFront() {
		while (!nodes_.empty) {
			auto node = nodes_.front;
			nodes_.popFront;

			if (node.isElementNode && selector_.matches(node)) {
				curr_ = node;
				return;
			}
		}
		curr_ = null;
	}

	private NodeType* curr_;
	private DescendantsDFForward!NodeType nodes_;
	private Selector selector_;
}


struct NodeWrapper(NodeType) {
	package this(NodeType* node) {
		node_ = node;
	}

	alias node_ this;
	NodeType* node_;

	auto opIndex(HTMLString name) const {
		return node_.attr(name);
	}

	void opIndexAssign(T)(T value, HTMLString name) {
		node_.attr(name, value.to!string);
	}

	@property auto id() const {
		return node_.attr("id");
	}

	@property void id(T)(T value) {
		node_.attr("id", value.to!string);
	}

	auto toString() const {
		return node_ ? node_.toString() : "null";
	}
}


enum NodeTypes : ubyte {
	Text = 0,
	Element,
	Comment,
	CDATA,
	Declaration,
	ProcessingInstruction,
}


struct Node {
	package this(Document* document, HTMLString tag) {
		tag_ = tag;
		document_ = document;
	}

	@property auto type() const {
		return (flags_ & TypeMask) >> TypeShift;
	}

	@property auto tag() const {
		return isElementNode ? tag_ : null;
	}

	void text(Appender)(ref Appender app) const {
		if (isTextNode) {
			app.put(tag_);
		} else {
			const(Node)* child = firstChild_;
			while (child) {
				child.text(app);
				child = child.next_;
			}
		}
	}

	@property auto text() {
		Appender!HTMLString app;
		text(app);
		return app.data;
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

	@property void html(size_t options = DOMCreateOptions.Default)(HTMLString html) {
		assert(isElementNode, "cannot add html to non-element nodes");

		enum parserOptions = ((options & DOMCreateOptions.DecodeEntities) ? ParserOptions.DecodeEntities : 0);

		destroyChildren();

		auto builder = DOMBuilder!(Document)(*document_, &this);
		parseHTML!(typeof(builder), parserOptions)(html, builder);
	}

	@property auto html() {
		Appender!HTMLString app;
		innerHTML(app);
		return app.data;
	}

	@property auto outerHTML() {
		Appender!HTMLString app;
		outerHTML!(typeof(app))(app);
		return app.data;
	}

	void prependChild(Node* node) {
		assert(document_ == node.document_);
		assert(isElementNode, "cannot prepend to non-element nodes");

		if (node.parent_)
			node.detach();
		node.parent_ = &this;
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

	void appendChild(Node* node) {
		assert(document_ == node.document_);
		assert(isElementNode, "cannot append to non-element nodes");

		if (node.parent_)
			node.detach();
		node.parent_ = &this;
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

	void removeChild(Node* node) {
		assert(node.parent_ == &this);
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
			assert(firstChild_.prev_ == null);
			firstChild_.prev_ = node;
			node.next_ = firstChild_;
			firstChild_ = node;
		} else {
			assert(lastChild_ == null);
			firstChild_ = node;
			lastChild_ = node;
		}
		node.parent_ = &this;
	}

	void appendText(HTMLString text) {
		auto node = document_.createTextNode(text);
		if (lastChild_) {
			assert(lastChild_.next_ == null);
			lastChild_.next_ = node;
			node.prev_ = lastChild_;
			lastChild_ = node;
		} else {
			assert(firstChild_ == null);
			firstChild_ = node;
			lastChild_ = node;
		}
		node.parent_ = &this;
	}

	void insertBefore(Node* node) {
		assert(document_ == node.document_);

		parent_ = node.parent_;
		prev_ = node.prev_;
		next_ = node;
		node.prev_ = &this;

		if (parent_ && (parent_.firstChild_ == node))
			parent_.firstChild_ = &this;
	}

	void insertAfter(Node* node) {
		assert(document_ == node.document_);

		parent_ = node.parent_;
		prev_ = node;
		next_ = node.next_;
		node.next_ = &this;
	}

	void detach() {
		if (parent_) {
			if (parent_.firstChild_ == &this) {
				parent_.firstChild_ = next_;
				if (next_) {
					next_.prev_ = null;
					next_ = null;
				} else {
					parent_.lastChild_ = null;
				}

				assert(prev_ == null);
			} else if (parent_.lastChild_ == &this) {
				parent_.lastChild_ = prev_;
				assert(prev_);
				assert(!next_);
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
			if (parent_.firstChild_ == &this) {
				parent_.firstChild_ = next_;
				if (next_) {
					next_.prev_ = null;
				} else {
					parent_.lastChild_ = null;
				}

				assert(prev_ == null);
			} else if (parent_.lastChild_ == &this) {
				parent_.lastChild_ = prev_;
				assert(prev_);
				assert(!next_);
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
		document_.destroyNode(&this);
	}

	void innerHTML(Appender)(ref Appender app) const {
		const(Node)* child = firstChild_;
		while (child) {
			child.outerHTML(app);
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
					app.put("=\"");
					writeHTMLEscaped(app, value);
					app.put("\"");
				}
			}

			if (!isSelfClosing) {
				app.put('>');
				switch (tagHashOf(tag_))
				{
				case tagHashOf("script"), tagHashOf("style"):
					text(app);
					break;
				default:
					innerHTML(app);
					break;
				}
				app.put("</");
				app.put(tag_);
				app.put('>');
			} else {
				app.put(" />");
			}
			break;
		case Text:
			writeHTMLEscaped(app, tag_);
			break;
		case Comment:
			app.put("<!--");
			app.put(tag_);
			app.put("-->");
			break;
		case CDATA:
			app.put("<[CDATA[");
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
					writeHTMLEscaped(app, value);
					app.put("\"");
				}
			}
			if (!isSelfClosing) {
				app.put("/>");
			} else {
				app.put(">");
			}
			break;
		case Text:
			writeHTMLEscaped(app, tag_);
			break;
		case Comment:
			app.put("<!--");
			app.put(tag_);
			app.put("-->");
			break;
		case CDATA:
			app.put("<[CDATA[");
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

	auto toString() const {
		Appender!HTMLString app;
		toString(app);
		return app.data;
	}

	@property auto parent() const {
		return wrap(parent_);
	}

	@property auto parent() {
		return wrap(parent_);
	}

	@property auto firstChild() const {
		return wrap(firstChild_);
	}

	@property auto firstChild() {
		return wrap(firstChild_);
	}

	@property auto lastChild() const {
		return wrap(lastChild_);
	}

	@property auto lastChild() {
		return wrap(lastChild_);
	}

	@property auto previousSibling() const {
		return wrap(prev_);
	}

	@property auto previousSibling() {
		return wrap(prev_);
	}

	@property auto nextSibling() const {
		return wrap(next_);
	}

	@property auto nextSibling() {
		return wrap(next_);
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

	@property auto descendants() const {
		return DescendantsDFForward!(const(Node))(firstChild_);
	}

	@property auto descendants() {
		return DescendantsDFForward!Node(firstChild_);
	}

	@property isSelfClosing() const {
		return (flags_ & Flags.SelfClosing) != 0;
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

package:
	enum TypeMask	= 0x7;
	enum TypeShift	= 0;
	enum FlagsBit	= TypeMask + 1;
	enum Flags {
		SelfClosing = FlagsBit << 1,
	}

	size_t flags_;
	HTMLString tag_; // when Text flag is set, will contain the text itself
	HTMLString[HTMLString] attrs_;

	Node* parent_;
	Node* firstChild_;
	Node* lastChild_;

	// siblings
	Node* prev_;
	Node* next_;

	Document* document_;
}


auto createDocument(size_t options = DOMCreateOptions.Default)(HTMLString source) {
	enum parserOptions = ((options & DOMCreateOptions.DecodeEntities) ? ParserOptions.DecodeEntities : 0);

	auto document = createDocument();
	auto builder = DOMBuilder!(Document)(document);

	parseHTML!(typeof(builder), parserOptions)(source, builder);
	return document;
}

unittest
{
	auto doc = createDocument(`<html><body>&nbsp;</body></html>`);
	assert(doc.root.outerHTML == `<root><html><body>&#160;</body></html></root>`);
	doc = createDocument!(DOMCreateOptions.None)(`<html><body>&nbsp;</body></html>`);
	assert(doc.root.outerHTML == `<root><html><body>&amp;nbsp;</body></html></root>`);
	doc = createDocument(`<script>&nbsp;</script>`);
	assert(doc.root.outerHTML == `<root><script>&nbsp;</script></root>`, doc.root.outerHTML);
	doc = createDocument(`<style>&nbsp;</style>`);
	assert(doc.root.outerHTML == `<root><style>&nbsp;</style></root>`, doc.root.outerHTML);
}

static auto createDocument() {
	auto document = Document();
	document.init();
	document.root(document.createElement("root"));
	return document;
}


struct Document {
	auto createElement(HTMLString tagName, Node* parent = null) {
		auto node = alloc_.alloc();
		*node = Node(&this, tagName);
		node.flags_ |= (NodeTypes.Element << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return wrap(node);
	}

	auto createTextNode(HTMLString text, Node* parent = null) {
		auto node = alloc_.alloc();
		*node = Node(&this, text);
		node.flags_ |= (NodeTypes.Text << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return wrap(node);
	}

	auto createCommentNode(HTMLString comment, Node* parent = null) {
		auto node = alloc_.alloc();
		*node = Node(&this, comment);
		node.flags_ |= (NodeTypes.Comment << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return wrap(node);
	}

	auto createCDATANode(HTMLString cdata, Node* parent = null) {
		auto node = alloc_.alloc();
		*node = Node(&this, cdata);
		node.flags_ |= (NodeTypes.CDATA << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return wrap(node);
	}

	auto createDeclarationNode(HTMLString data, Node* parent = null) {
		auto node = alloc_.alloc();
		*node = Node(&this, data);
		node.flags_ |= (NodeTypes.Declaration << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return wrap(node);
	}

	auto createProcessingInstructionNode(HTMLString data, Node* parent = null) {
		auto node = alloc_.alloc();
		*node = Node(&this, data);
		node.flags_ |= (NodeTypes.ProcessingInstruction << Node.TypeShift);
		if (parent)
			parent.appendChild(node);
		return wrap(node);
	}

	void destroyNode(Node* node) {
		alloc_.free(node);
	}

	@property auto root() {
		return wrap(root_);
	}

	@property auto root() const {
		return wrap(root_);
	}

	@property auto root(Node* root) {
		root_ = root;
	}

	@property auto nodes() const {
		return DescendantsDFForward!(const(Node))(root_);
	}

	@property auto nodes() {
		return DescendantsDFForward!Node(root_);
	}

	@property auto elements() const {
		return DescendantsDFForward!(const(Node), mixin(OnlyElements))(root_);
	}

	@property auto elements() {
		return DescendantsDFForward!(Node, mixin(OnlyElements))(root_);
	}

	@property auto elementsByTagName(HTMLString tag) const {
		return DescendantsDFForward!(const(Node), (a) { return a.isElementNode && (a.tag.equalsCI(tag)); })(root_);
	}

	@property auto elementsByTagName(HTMLString tag) {
		return DescendantsDFForward!(Node, (a) { return a.isElementNode && (a.tag.equalsCI(tag)); })(root_);
	}

	NodeWrapper!Node querySelector(HTMLString selector, Node* context = null) {
		auto rules = Selector.parse(selector);
		return querySelector(rules, context);
	}

	NodeWrapper!Node querySelector(Selector selector, Node* context = null) {
		auto top = context ? context : root_;

		foreach(node; DescendantsDFForward!(Node, mixin(OnlyElements))(top)) {
			if (selector.matches(node))
				return node;
		}
		return NodeWrapper!Node(null);
	}

	QuerySelectorAll!Node querySelectorAll(HTMLString selector, Node* context = null) {
		auto rules = Selector.parse(selector);
		return querySelectorAll(rules, context);
	}

	QuerySelectorAll!Node querySelectorAll(Selector selector, Node* context = null) {
		auto top = context ? context : root_;
		return QuerySelectorAll!Node(selector, top);
	}

	void toString(Appender)(ref Appender app) const {
		root_.outerHTML(app);
	}

	HTMLString toString() const {
		auto app = appender!HTMLString;
		root_.outerHTML(app);
		return app.data;
	}

private:
	void init() {
		alloc_.init;
	}

	Node* root_;
	PageAllocator!(Node, 1024) alloc_;
}


struct DOMBuilder(Document) {
	this(ref Document document, Node* parent = null) {
		document_ = &document;
		element_ = parent ? parent : document.root;
	}

	void onText(HTMLString data) {
		if (data.ptr == (text_.ptr + text_.length)) {
			text_ = text_.ptr[0..text_.length + data.length];
		} else {
			text_ ~= data;
		}
	}

	void onSelfClosing() {
		element_.flags_ |= Node.Flags.SelfClosing;
		element_ = element_.parent_;
	}

	void onOpenStart(HTMLString data) {
		if (!text_.empty) {
			element_.appendText(text_);
			text_.length = 0;
		}

		auto element = document_.createElement(data, element_);
		element_ = element;
	}

	void onOpenEnd(HTMLString data) {
		auto hash = tagHashOf(element_.tag);
		switch (hash) {
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
			onSelfClosing();
			break;
		default:
			break;
		}
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
			auto element = element_;

			while (element) {
				if (element.tag.equalsCI(data)) {
					element_ = element_.parent_;
					break;
				}
				element = element.parent_;
			}
		}
	}

	void onAttrName(HTMLString data) {
		attr_ = data;
		state_ = States.Attr;
	}

	void onAttrEnd() {
		if (!attr_.empty)
			element_.attr(attr_, value_);
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
	Document* document_;
	Node* element_;
	States state_;

	enum States {
		Global = 0,
		Attr,
	}

	HTMLString attr_;
	HTMLString value_;
	HTMLString text_;
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
					if (index && !isSpace(attr[index - 1]))
						return false;
					if ((index + value_.length == attr.length) || isSpace(attr[index + value_.length]))
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
			case hashOf("checked"):
				if (!element.hasAttr("checked"))
					return false;
				break;

			case hashOf("enabled"):
				if (element.hasAttr("disabled"))
					return false;
				break;

			case hashOf("disabled"):
				if (!element.hasAttr("disabled"))
					return false;
				break;

			case hashOf("empty"):
				if (element.firstChild_)
					return false;
				break;

			case hashOf("optional"):
				if (element.hasAttr("required"))
					return false;
				break;

			case hashOf("read-only"):
				if (!element.hasAttr("readonly"))
					return false;
				break;

			case hashOf("read-write"):
				if (element.hasAttr("readonly"))
					return false;
				break;

			case hashOf("required"):
				if (!element.hasAttr("required"))
					return false;
				break;

			case hashOf("lang"):
				if (element.attr("lang") != pseudoArg_)
					return false;
				break;

			case hashOf("first-child"):
				if (!element.parent_ || (element.parent_.firstChild != element))
					return false;
				break;

			case hashOf("last-child"):
				if (!element.parent_ || (element.parent_.lastChild != element))
					return false;
				break;

			case hashOf("first-of-type"):
				auto sibling = element.previousSibling;
				while (sibling) {
					if (sibling.isElementNode && sibling.tag.equalsCI(element.tag))
						return false;
					sibling = sibling.previousSibling;
				}
				break;

			case hashOf("last-of-type"):
				auto sibling = element.nextSibling;
				while (sibling) {
					if (sibling.isElementNode && sibling.tag.equalsCI(element.tag))
						return false;
					sibling = sibling.nextSibling;
				}
				break;

			case hashOf("nth-child"):
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

			case hashOf("nth-last-child"):
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

			case hashOf("nth-of-type"):
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

			case hashOf("nth-last-of-type"):
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

			case hashOf("only-of-type"):
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

			case hashOf("only-child"):
				auto parent = element.parent_;
				if (!parent)
					return false;
				auto sibling = parent.firstChild_;
				while (sibling) {
					if ((sibling != element) && sibling.isElementNode)
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

	@property Relation relation() {
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
				state = AttrOp;
				continue;

			case AttrOp:
				while ((ptr != end) && (isSpace(*ptr)))
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
				while ((ptr != end) && isSpace(*ptr))
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
				while ((ptr != end) && !isSpace(*ptr) && (*ptr != ']'))
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
					rule.flags_ &= ~(Rule.Flags.CaseSensitive);
				}
				break;

			case Pseudo:
				while ((ptr != end) && (isAlpha(*ptr) || (*ptr == '-')))
					++ptr;
				if (ptr == end)
					continue;

				rule.pseudo_ = hashOf(start[0..ptr-start]);
				rule.flags_ |= Rule.Flags.HasPseudo;
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
				while ((ptr != end) && isSpace(*ptr))
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

		return selector;
	}

	bool matches(NodeType)(NodeType element) {
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

private:
	HTMLString source_;
	Rule[] rules_;
}

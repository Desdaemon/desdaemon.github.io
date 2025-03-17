---
title: "Rolling your own LSP testing framework, in Rust"
category: Testing
tags:
    - testing
    - ci
    - lsp
    - rust
---

Hello there, it's been more than a year since the last update. As usual, I'm still busy with [odoo-lsp](https://github.com/Desdaemon/odoo-lsp), a language server providing code services for Odoo-specific Python, Javascript and XML. Many asked me why is it necessary to build something like this in this new age of LLMs and "vibe coding", where the AI can get you 80% the way there every time and smarter ones even offer to do all the work for you. For me, it's half appalling to see these tools automate many of the menial steps of my day job, and half relieving to know that Odoo can sometimes be too complex for both humans and machine, both on a technical and functional level. As someone who is paid to do software development, I think I owe it to myself to improve my day-to-day experience working on such a convoluted codebase, and thus my commitment to odoo-lsp so far despite the viability of [several](https://plugins.jetbrains.com/plugin/13083-odoo-autocompletion-support) [competing](https://marketplace.visualstudio.com/items?itemName=trinhanhngoc.vscode-odoo) [projects](https://marketplace.visualstudio.com/items?itemName=Odoo.odoo). And last but not least, trying to write the simplest code possible to achieve something as complex as coding services gives me a brain workout every time I come back fresh to the codebase.

Anyways, enough rambling. If you came here from a Google search, congrats! You are probably in a unique position as an architect of some project, which requires some sort of testing for your bespoken language server project. Even after completing the refactor from [pytest-lsp](https://lsp-devtools.readthedocs.io/en/release/pytest-lsp/guide/getting-started.html) to pure Rust I'm still not sure if it will cover all of my needs, but there is one thing I'm pretty aware: the async ecosystem that tokio has created and nurtured is so much better than asyncio. While this blog details the steps done in Rust, the general idea can be applied to any language, but preferably the same language you wrote your language server in.

## A brief introduction to fixtures

As they are used in `pytest`, *fixtures* refer to a form of [dependency injection]: you provide a function that returns something, then later use it just by including it in the parameters of your test function:

```python
# Copied from https://docs.pytest.org/en/7.1.x/how-to/fixtures.html#quick-example
# Arrange
@pytest.fixture
def fruit_bowl():
    return [Fruit("apple"), Fruit("banana")]


def test_fruit_salad(fruit_bowl):
    # Act
    fruit_salad = FruitSalad(*fruit_bowl)

    # Assert
    assert all(fruit.cubed for fruit in fruit_salad.fruit)
```

Notice how you only gave a *definition* of `fruit_bowl`, but it somehow got automagically provided to `test_fruit_salad`! While it seems like it would have been trivial to call `fruit_bowl` ourselves in the testing function itself, the main advantages fixtures bring are *mockability* and *shareability*. Actually, this is not how I was introduced to fixtures, because in the projects I witnessed fixtures being used, they almost always referred to *text files* that are then later turned into test cases by some framework. Spoiler alert, we're writing one today.

A common use-case of text file fixtures is to provide them in an input-output pair, as in the case of testing compilers: you always want your compiler to work at least in this one way, and fixtures provide a natural way to bolster regression testing after a bug has been discovered. They can also be used for test-driven development, where you write the *inputs* you want your compiler (or in this case language server) to turn into some specifc *output*, and you want to be able to add new test cases just by adding new files, not code. An advantage with this approach is that the experience of writing test is practically painless: text files require much less rigor in how they should be structured, and you can even write comments right where you want. The concept extends to entire directories and even binary files as well: golden tests have you generate *known good* samples of (binary) output and ensures that your CI workflow tests that the outputs are still correct after every commit. Having the entire context of the test available just by reading the fixtures, and being able to *describe* the desired results rather than having to write your tests to encode your expectations is why fixtures are so powerful, for the projects that can make use of them.

## The Good, The Bad, The Messed Up

Alright, before we go off writing our own testing mini-framework, let's take a look at some prior art first. I've mentioned pytest-lsp before, and [here](https://lsp-devtools.readthedocs.io/en/release/pytest-lsp/guide/getting-started.html#a-simple-test-case)'s how the average test plays out:

```python
# Copied from https://lsp-devtools.readthedocs.io/en/release/pytest-lsp/guide/getting-started.html#a-simple-test-case
# -- cut --

@pytest_lsp.fixture(
    config=ClientServerConfig(server_command=[sys.executable, "server.py"]),
)
async def client(lsp_client: LanguageClient):
    # Setup
    params = InitializeParams(capabilities=ClientCapabilities())
    await lsp_client.initialize_session(params)

    yield

    # Teardown
    await lsp_client.shutdown_session()

# Then we use `client` like this
@pytest.mark.asyncio
async def test_completions(client: LanguageClient):
    """Ensure that the server implements completions correctly."""

    results = await client.text_document_completion_async(
        params=CompletionParams(
            position=Position(line=1, character=0),
            text_document=TextDocumentIdentifier(uri="file:///path/to/file.txt"),
        )
    )
    assert results is not None

    if isinstance(results, CompletionList):
        items = results.items
    else:
        items = results

    labels = [item.label for item in items]
    assert labels == ["hello", "world"]
```
{:file="test_server.py"}

As you can see, the steps described here are pretty manual: you get your LSP client, you make requests one by one, and you cross-check them with some expected values. Pretty easy to write, but this gets out of hand quickly if we suddenly need to start making dozens of requests! And this is only handling the `completion` command and not much else. Mayhaps some *automation* can be done here, don't you think?

Before we go off the deep end, I'll need to explain the goals of testing in the scope of odoo-lsp. For each test case, it needs to happen in an isolated module structure, i.e. a directory containing many Python modules:

```
testing/
└── fixtures/
    ├── test_case_1              # this must be isolated from all other fixtures
    │   ├── .odoo_lsp            # this is the LSP config file
    │   ├── foo                  # Each Odoo "module" needs at least these two files:
    │   │   ├── __manifest__.py  # a file that describes the module's metadata
    │   │   ├── __init__.py      # and a standard Python entrypoint
    │   │   └── foobar.py        # these are the files we want to test on
    │   └── bar/
    │       ├── __manifest__.py
    │       └── __init__.py
    ├── test_case_2
    ├── ...
    └── test_case_n
```

So in these fixtures, which in actual usage would be filled with Python files, are places where we can put our fixtures alongside with our test runners.

What exactly do we want to test our language server on? On request responses, of course! Just like in the simple example above, where you manually do all of these steps:
- You had to initialize the LSP client, which thankfully pytest-lsp offered to do on your behalf
- You had to make a *request* for a specific file, at a very specific position
- You had to *compare* the results with something you *expect*

What if you could automate all of that work? What if all the information the test runner needs to know, already exists in the fixture file? Here's what it could look like:

```python
class Foo(Models):
    _name = 'foo'

    my_field = Char()

    def main(self):
        self.
        #   ^complete main my_field
        # We should get completions for both the field and method here.
```
{:file="testing/fixtures/test_case_1/foobar.py"}

Notice that little comment with the leading caret? In our case, we are describing the expected results of the command `complete`, at the position immediately above the caret, alongside with what we want from the response. It's a very concise syntax for these kinds of tests, wouldn't you agree? Let's go over what we need to extract from a fixture:

- We need to figure out *which* commands we want to support: `complete` and `diagnostics` seems to be perfect for this use-case, since they both have simple outputs that can be compared by strings.
- We need to *parse* all of the visible *commands*, and feed them to an automated testing procedure.
- We also need to figure out what *changed* between the fixture and the actual output.

Python is well-equipped to deal with all three of these issues, since the tools required have all been developed a long time ago and are battle-tested. It even comes with its own parser in the [`ast`](https://docs.python.org/3/library/ast.html) library, so you can just feed it text and it would output a syntax tree ready to be processed! Here's a skeleton if you want to get started; heck, go ahead and get some AI to fill them out if you have to:

```py
# We need to put test configuration in this special file called conftest.py

@pytest.fixture
def rootdir():
    return __dirname # the directory that contains this file
```
{:file="testing/fixtures/test_case_1/conftest.py"}

```py
@pytest.mark.asyncio(loop_scope="module")
async def test_case_1(client: LanguageClient, rootdir: str):
    # our inputs are the client we defined earlier;
    # and the rootdir, which will change between tests.

    # read all Python files in the current directory ...
    # parse them into ASTs and extract the comments ...
    # try to parse the commands from the comments ...
    # for each command, make the corresponding request and compare results ...
    pass
```
{:file="testing/fixtures/test_case_1/test_case_1.py"}

And once you're done with your first test case, you can refactor your testing routine (so that it does not depend on the working directory but only `rootdir`) and you're pretty much done! For all subsequent tests you only have to add Python *fixture* files, not making the requests yourself. Implementing new commands are also easier if you know how the first one was done, so here's a freebie from odoo-lsp:

```py
class Expected:
    complete: list[tuple[Position, list[str]]]

    def __init__(self):
        self.complete = []

async def fixture_test():
    expected = defaultdict[str, Expected](Expected)
    files = dict[str, str]()

    # I use tree-sitter as the Python parser here,
    # it will all be explained later
    asts: dict[str, 'tree_sitter.Node']()

    # parse all your commands into `expected`
    # -- cut --

    unexpected = list[str]()
    for file, text in files.items():
        # -- cut --
        for pos, expected_completion in expected[file].complete:
            results = await client.text_document_completion_async(
                CompletionParams(
                    TextDocumentIdentifier(uri=file.as_uri()),
                    pos,
                )
            )
            if not expected_completion:
                assert not results
                continue
            if not isinstance(results, CompletionList):
                unexpected.append(f"complete: unexpected empty list\n  at {file}:{inc(pos)}")
                continue
            actual = [e.label for e in results.items]
            if actual != expected_completion:
                # the *smallest* AST node that contains this range
                # in this case we're adding for a node that contains the rest of the line
                node = asts[file].root_node.named_descendant_for_point_range(
                    (pos.line, pos.character), (pos.line, 9999)
                )
                assert node
                if text := node.text:
                    node_text = text.decode()
                else:
                    node_text = ""
                # Get fancy here, it's your own framework!
                unexpected.append(
                    f"complete: actual={' '.join(actual)}\n"
                    f"  at {file}:{inc(pos)}\n"
                    f"{' ' * node.start_point.column}{node_text}"
                )
```
{:file="odoo-lsp/testing/common.py"}

Running the tests on GitHub CI will get you something like this (when tests are failing, anyways):

[![GitHub CI Fixture Test Results](/assets/images/github_ci_fixtures.png)](https://github.com/Desdaemon/odoo-lsp/actions/runs/13646892830/job/38147326522#step:12:163)

(It's so red! Must not have been a good day for me...)

As alluded to before, this may seem like a lot of work but it will be repaid many times over. You are no longer limited by your ability to write Python test code fast, you only need to add enough test cases and your language server will be decently tested. Of course this doesn't cover more complex commands like goto-definitions or symbol search, but you can always test them manually or use and parse another form of fixture.

I'll also briefly explain the choice of using [tree-sitter](https://tree-sitter.github.io/tree-sitter/) for this mini-framework. By itself, tree-sitter can't do much, because it's a meta-framework for *compilers* to be written in a simple Javascript [DSL](https://en.wikipedia.org/wiki/Domain-specific_language), which then generates C code to be compiled and executed. The community has rallied around tree-sitter for so long, there are practically parsers for every language you could think of; some languages even use tree-sitter to prototype their parsers! And of course odoo-lsp also uses it, so it's definitely more out of familiarity than anything that led me to choose this library as the parser.

One of the more powerful features tree-sitter has is the ability to write complex *queries* about any given syntax tree. The closest analogy I have is SQL tables and queries: you have tables with fixed structure, and you can ask for data in those tables that fit certain conditions and even manipulate the output data. tree-sitter can't generate new data, but it can *match* over a contiguous selection of nodes, capturing their positions in the process and splays them in a neat list format. In fact, to parse the comments into LSP commands, I used tree-sitter to implement them as well:

```scheme
((comment) @complete
  (#match? @complete "\\^complete "))
```

When this Scheme file is passed to tree-sitter to create a Query, it does a few things:

- It looks for all the `comment` nodes in the entire AST
- It captures the position of all the nodes marked with `@complete`
- It filters out only nodes whose *text content* matches the provided regex pattern
- And it returns to you an iterator of lists of nodes!

Compare this with `ast`, where you'd have to either dig down an AST or implement some form of visitor to cover all the comment nodes.


[dependency injection]: https://en.wikipedia.org/wiki/Dependency_injection

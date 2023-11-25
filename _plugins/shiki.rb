# frozen_string_literal: true

module Jekyll
  class ShikiHighlightBlock < Liquid::Block
    def initialize(tag_name, lang, tokens)
      super
      @lang = lang.strip
    end

    @@shiki = nil
    @@mutex = Mutex.new
    def with_shiki(&blk)
      @@mutex.synchronize do
        yield @@shiki ||= IO.popen(["node",  "_scripts/shiki.js"], "a+")
      end
    end

    def render(context)
      code = super
      output = with_shiki do |shiki|
        shiki.write @lang, ';', code.gsub("\n", '\n'), "\n"
        shiki.readline.gsub('\n', "\n")
      end
      lang = @lang == "ts" ? "TypeScript" : "JavaScript"
      <<~OUTPUT
      <div class="language-#{@lang}">
        <div class="code-header">
          <span data-label-text="#{lang}">
            <i class="fas fa-code fa-fw small"></i>
          </span>
          <button aria-label="copy" data-title-succeed="Copied!">
            <i class="far fa-clipboard"></i>
          </button>
        </div>
        <code>
          <div class="rouge-code">
            #{output}
          </div>
        </code>
      </div>
      OUTPUT
    end
  end
end

Liquid::Template.register_tag("shiki", Jekyll::ShikiHighlightBlock)

pattern = /```(\w+) twoslash([^\0]*?)\n?```/
Jekyll::Hooks.register :posts, :pre_render do |page|
  page.content = page.content.gsub(pattern, '{% shiki \1 %}\2{% endshiki %}')
end

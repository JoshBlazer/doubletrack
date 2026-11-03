# frozen_string_literal: true

require "cgi"
require "nokogiri"

module Doubletrack
  module Normalize
    # HTML bodies (ADR 0017): parsed with Nokogiri into a tree of
    # {"tag", "attrs" (sorted), "children"}. Text is whitespace-collapsed (except inside
    # pre/textarea), whitespace-only text and comments are dropped, and volatile tokens are
    # stripped: CSRF meta content, authenticity_token input values, nonce attributes.
    module Html
      PRESERVE = %w[pre textarea].freeze
      VOLATILE_META = %w[csrf-token csp-nonce].freeze
      TOKEN_INPUTS = %w[authenticity_token].freeze
      VOID = %w[area base br col embed hr img input link meta source track wbr].freeze

      module_function

      # @param html [String] a document or a fragment
      # @return [Hash] {"tag" => "#document", "children" => [...]}
      def call(html)
        doc = document?(html) ? Nokogiri::HTML5(html.to_s) : Nokogiri::HTML5.fragment(html.to_s)
        {"tag" => "#document", "attrs" => {}, "children" => children(doc, preserve: false)}
      end

      # Canonical HTML text of {call}; parsing it again yields the same tree.
      # @return [String]
      def canonical(html)
        serialize(call(html)["children"])
      end

      def document?(html)
        html.to_s.lstrip.match?(/\A(?:<!doctype|<html)/i)
      end

      def children(node, preserve:)
        node.children.filter_map do |child|
          if child.element?
            element(child, preserve: preserve)
          elsif child.text? || child.cdata?
            text = preserve ? child.text : child.text.gsub(/\s+/, " ").strip
            text.empty? ? nil : text
          end
        end.then { |list| merge_text(list) }
      end

      def element(el, preserve:)
        name = el.name.downcase
        attrs = el.attribute_nodes.to_h { |a| [a.name.downcase, a.value] }
        attrs.delete("nonce")
        attrs["content"] = "" if name == "meta" && VOLATILE_META.include?(attrs["name"]) && attrs.key?("content")
        attrs["value"] = "" if name == "input" && TOKEN_INPUTS.include?(attrs["name"]) && attrs.key?("value")
        keep = preserve || PRESERVE.include?(name)
        {"tag" => name, "attrs" => attrs.sort.to_h, "children" => children(el, preserve: keep)}
      end

      # Adjacent text nodes (e.g. split around a dropped comment) become one.
      def merge_text(list)
        list.each_with_object([]) do |item, out|
          if item.is_a?(String) && out.last.is_a?(String)
            out[-1] = "#{out.last} #{item}"
          else
            out << item
          end
        end
      end

      def serialize(nodes)
        nodes.map do |node|
          next CGI.escapeHTML(node) if node.is_a?(String)

          attrs = node["attrs"].map { |k, v| %( #{k}="#{CGI.escapeHTML(v)}") }.join
          next "<#{node["tag"]}#{attrs}>" if VOID.include?(node["tag"])

          "<#{node["tag"]}#{attrs}>#{serialize(node["children"])}</#{node["tag"]}>"
        end.join
      end
    end
  end
end

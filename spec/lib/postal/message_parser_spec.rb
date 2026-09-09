# frozen_string_literal: true

require "rails_helper"

describe Postal::MessageParser do
  let(:server) { create(:server) }

  def links_for(message)
    message.server.message_db.select(:links, where: { message_id: message.id })
  end

  def reparse(parser)
    Mail.new("#{parser.new_headers}\r\n\r\n#{parser.new_body}")
  end

  def tracked_url_regex(domain, server)
    /https:\/\/click\.#{Regexp.escape(domain.name)}\/#{server.token}\/[A-Za-z0-9]{16}/
  end

  def create_html_message(server, domain, html)
    MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
      mail.html_part = Mail::Part.new do
        content_type "text/html; charset=UTF-8"
        body html
      end
    end
  end

  it "should not do anything when there are no tracking domains" do
    expect(server.track_domains.size).to eq 0
    message = create_plain_text_message(server, "Hello world!", "test@example.com")
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be false
    expect(parser.tracked_links).to eq 0
    expect(parser.tracked_images).to eq 0
  end

  it "should replace links in messages" do
    message = create_plain_text_message(server, "Hello world! http://github.com/atech/postal", "test@example.com")
    create(:track_domain, server: server, domain: message.domain)
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be true
    expect(parser.new_body).to match(/^Hello world! https:\/\/click\.#{message.domain.name}/)
    expect(parser.tracked_links).to eq 1
  end

  it "should rewrite links and insert a tracking image in HTML messages" do
    domain = create(:domain, owner: server)
    message = MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
      mail.html_part = Mail::Part.new do
        content_type "text/html; charset=UTF-8"
        body %(<html><body><p><a href="https://github.com/atech/postal">Postal</a></p></body></html>)
      end
    end
    create(:track_domain, server: server, domain: domain)
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be true
    expect(parser.tracked_links).to eq 1
    expect(parser.tracked_images).to eq 1
    expect(parser.new_body).to include("href='https://click.#{domain.name}/")
    expect(parser.new_body).to include("class='ampimg'")
  end

  it "should not rewrite links for excluded click domains" do
    message = create_plain_text_message(server, "Hello world! http://github.com/atech/postal", "test@example.com")
    create(:track_domain, server: server, domain: message.domain, excluded_click_domains: "github.com")
    parser = Postal::MessageParser.new(message)
    expect(parser.tracked_links).to eq 0
    expect(parser.new_body).to include("http://github.com/atech/postal")
  end

  it "should not rewrite links or insert images when tracking is disabled on the track domain" do
    domain = create(:domain, owner: server)
    message = MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
      mail.html_part = Mail::Part.new do
        content_type "text/html; charset=UTF-8"
        body %(<html><body><a href="https://github.com/atech/postal">Postal</a></body></html>)
      end
    end
    create(:track_domain, server: server, domain: domain, track_clicks: false, track_loads: false)
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be false
    expect(parser.tracked_links).to eq 0
    expect(parser.tracked_images).to eq 0
  end

  it "should strip the +notrack marker when there is no track domain at all" do
    message = create_plain_text_message(server, "Hello world! http+notrack://github.com/atech/postal", "test@example.com")
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be true
    expect(parser.new_body).to include("http://github.com/atech/postal")
    expect(parser.new_body).not_to include("+notrack")
  end

  it "should not parse the message when the track domain's DNS isn't OK and there is nothing to strip" do
    message = create_plain_text_message(server, "Hello world! http://github.com/atech/postal", "test@example.com")
    create(:track_domain, server: server, domain: message.domain, dns_status: "Missing")
    expect(Mail).not_to receive(:new)
    expect(described_class.new(message).actioned?).to be false
  end

  it "should strip the +notrack marker even when the track domain's DNS isn't OK" do
    message = create_plain_text_message(server, "Hello world! http+notrack://github.com/atech/postal", "test@example.com")
    create(:track_domain, server: server, domain: message.domain, dns_status: "Missing")
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be true
    expect(parser.new_body).not_to include("+notrack")
    expect(parser.new_body).to include("http://github.com/atech/postal")
    expect(parser.tracked_links).to eq 0
  end

  describe "URL_REGEX" do
    let(:regex) { described_class::URL_REGEX }

    it "matches http URLs and captures the protocol, domain and path" do
      match = regex.match("http://example.com/some/path")
      expect(match[:url]).to eq "http://example.com/some/path"
      expect(match[:protocol]).to eq "http"
      expect(match[:domain]).to eq "example.com"
      expect(match[:path]).to eq "/some/path"
    end

    it "matches https URLs" do
      expect(regex.match("https://example.com/")[:protocol]).to eq "https"
    end

    it "matches URLs without a path" do
      match = regex.match("http://example.com")
      expect(match[:url]).to eq "http://example.com"
      expect(match[:path]).to be_nil
    end

    it "includes the port in the domain capture" do
      match = regex.match("http://example.com:8080/x")
      expect(match[:domain]).to eq "example.com:8080"
      expect(match[:path]).to eq "/x"
    end

    it "matches query strings and fragments in the path" do
      match = regex.match("https://example.com/search?q=postal&page=2#results")
      expect(match[:path]).to eq "/search?q=postal&page=2#results"
    end

    it "matches paths containing the full set of allowed characters" do
      url = "https://example.com/a.b/c~d;e:f=g%20h+i_j-k(l)[m]?n&o#p"
      expect(regex.match(url)[:url]).to eq url
    end

    it "matches sub-domains, hyphens and digits in the domain" do
      expect(regex.match("http://a-b.c1.example.co.uk/x")[:domain]).to eq "a-b.c1.example.co.uk"
    end

    it "matches IPv4 hosts" do
      expect(regex.match("http://127.0.0.1:3000/x")[:domain]).to eq "127.0.0.1:3000"
    end

    it "does not match bracketed IPv6 hosts" do
      expect(regex.match("http://[::1]/x")).to be_nil
    end

    it "does not match upper-case protocols" do
      expect(regex.match("HTTP://example.com/x")).to be_nil
      expect(regex.match("Https://example.com/x")).to be_nil
    end

    it "does not match non-http protocols" do
      expect(regex.match("ftp://example.com/x")).to be_nil
      expect(regex.match("mailto:test@example.com")).to be_nil
    end

    it "does not match protocol-relative URLs" do
      expect(regex.match("//example.com/x")).to be_nil
    end

    it "stops the path at whitespace" do
      expect(regex.match("http://example.com/a b")[:url]).to eq "http://example.com/a"
      expect(regex.match("http://example.com/a\tb")[:url]).to eq "http://example.com/a"
      expect(regex.match("http://example.com/a\r\nb")[:url]).to eq "http://example.com/a"
    end

    it "stops the path at characters outside the allowed set" do
      expect(regex.match("http://example.com/a,b")[:url]).to eq "http://example.com/a"
      expect(regex.match("http://example.com/a!b")[:url]).to eq "http://example.com/a"
      expect(regex.match("http://example.com/a|b")[:url]).to eq "http://example.com/a"
      expect(regex.match("http://example.com/a@b")[:url]).to eq "http://example.com/a"
      expect(regex.match("http://example.com/a'b")[:url]).to eq "http://example.com/a"
      expect(regex.match(%(http://example.com/a"b))[:url]).to eq "http://example.com/a"
      expect(regex.match("http://example.com/a*b")[:url]).to eq "http://example.com/a"
      expect(regex.match("http://example.com/a$b")[:url]).to eq "http://example.com/a"
    end

    it "stops the domain at characters outside the allowed set" do
      expect(regex.match("http://example.com,")[:domain]).to eq "example.com"
      expect(regex.match("http://user:pw@example.com/")[:domain]).to eq "user:pw"
    end

    it "includes trailing dots in the domain capture" do
      expect(regex.match("http://example.com.")[:domain]).to eq "example.com."
    end

    it "matches when the URL is embedded in other text" do
      expect(regex.match("see http://example.com/x now")[:url]).to eq "http://example.com/x"
      expect(regex.match("foohttp://example.com/x")[:url]).to eq "http://example.com/x"
    end
  end

  describe "plain text link rewriting" do
    let(:message) { create_plain_text_message(server, text, "test@example.com") }
    let(:domain) { message.domain }
    let(:parser) { Postal::MessageParser.new(message) }
    let(:text_body) { reparse(parser).text_part.decoded }

    before do
      create(:track_domain, server: server, domain: domain, track_loads: false)
    end

    context "with an http URL" do
      let(:text) { "Visit http://github.com/atech/postal today" }

      it "replaces the URL with a tracking link" do
        expect(parser.tracked_links).to eq 1
        expect(text_body).to match(/\AVisit #{tracked_url_regex(domain, server)} today/)
      end

      it "stores the original URL against the generated token" do
        parser
        link = links_for(message).first
        expect(link["url"]).to eq "http://github.com/atech/postal"
        expect(text_body).to include("/#{server.token}/#{link['token']}")
      end

      it "marks the message as actioned" do
        expect(parser.actioned?).to be true
      end
    end

    context "with an https URL" do
      let(:text) { "https://github.com/atech/postal" }

      it "replaces the URL with a tracking link" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "https://github.com/atech/postal"
      end
    end

    context "with a URL without a path" do
      let(:text) { "Go to http://github.com" }

      it "tracks the URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://github.com"
      end
    end

    context "with a query string and fragment" do
      let(:text) { "http://github.com/search?q=postal&type=code&page=2#results" }

      it "stores the complete URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq text
      end
    end

    context "with a port" do
      let(:text) { "http://github.com:8443/atech/postal" }

      it "stores the complete URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq text
      end
    end

    context "with a percent-encoded path" do
      let(:text) { "http://github.com/a%20b/c%2Fd" }

      it "stores the complete URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq text
      end
    end

    context "with an IPv6 host" do
      let(:text) { "http://[2001:db8::1]/path" }

      it "leaves the URL untouched" do
        expect(parser.tracked_links).to eq 0
        expect(text_body).to include(text)
      end
    end

    context "with an upper-case protocol" do
      let(:text) { "HTTP://github.com/atech/postal" }

      it "leaves the URL untouched" do
        expect(parser.tracked_links).to eq 0
        expect(text_body).to include(text)
      end
    end

    context "with non-http protocols" do
      let(:text) { "ftp://github.com/x mailto:test@github.com" }

      it "leaves them untouched" do
        expect(parser.tracked_links).to eq 0
        expect(text_body).to include(text)
      end
    end

    context "with multiple URLs on separate lines" do
      let(:text) { "First: http://github.com/one\r\nSecond: https://github.com/two\r\nDone" }

      it "tracks each URL with a distinct token" do
        expect(parser.tracked_links).to eq 2
        links = links_for(message)
        expect(links.map { |l| l["url"] }).to contain_exactly("http://github.com/one", "https://github.com/two")
        expect(links.map { |l| l["token"] }.uniq.size).to eq 2
        expect(text_body).not_to include("github.com")
      end
    end

    context "with the same URL repeated" do
      let(:text) { "http://github.com/x and http://github.com/x" }

      it "creates a link record for each occurrence" do
        expect(parser.tracked_links).to eq 2
        expect(links_for(message).size).to eq 2
      end
    end

    context "with a URL at the very end of the text" do
      let(:text) { "See http://github.com/atech/postal" }

      it "tracks the URL" do
        expect(parser.tracked_links).to eq 1
      end
    end

    context "with a URL followed directly by a disallowed character" do
      let(:text) { "http://github.com/x|y" }

      it "does not track the URL because it isn't followed by whitespace" do
        expect(parser.tracked_links).to eq 0
        expect(text_body).to include(text)
      end
    end

    context "with a URL ending in a full stop" do
      let(:text) { "Visit http://github.com/atech/postal." }

      it "trims the full stop from the stored URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://github.com/atech/postal"
      end

      it "keeps the full stop in the rewritten text" do
        expect(text_body).to match(/#{tracked_url_regex(domain, server)}\.\s*\z/)
      end
    end

    context "with a domain-only URL ending in a full stop" do
      let(:text) { "Visit http://github.com." }

      it "trims the full stop from the stored URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://github.com"
      end
    end

    context "with a URL wrapped in parentheses" do
      let(:text) { "(see http://github.com/atech/postal)" }

      it "trims the closing parenthesis from the stored URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://github.com/atech/postal"
      end

      it "keeps the closing parenthesis in the rewritten text" do
        expect(text_body).to match(/\(see #{tracked_url_regex(domain, server)}\)/)
      end
    end

    context "with a URL ending in several punctuation characters" do
      let(:text) { "Look: http://github.com/atech/postal?)." }

      it "trims all of them from the stored URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://github.com/atech/postal"
      end
    end

    context "with a URL ending in a slash" do
      let(:text) { "http://github.com/atech/postal/" }

      it "trims the trailing slash from the stored URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://github.com/atech/postal"
      end
    end

    context "with a URL ending in an empty query parameter" do
      let(:text) { "http://github.com/?a=b&c=" }

      it "trims the trailing equals sign from the stored URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://github.com/?a=b&c"
      end
    end

    context "with a URL containing balanced parentheses" do
      let(:text) { "http://en.wikipedia.org/wiki/Foo_(bar)" }

      it "stores the URL with its closing parenthesis" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq text
      end
    end

    context "with a URL followed by a comma" do
      let(:text) { "See http://github.com/atech/postal, it is great" }

      it "tracks the URL" do
        expect(parser.tracked_links).to eq 1
      end
    end

    context "with a URL followed by an exclamation mark" do
      let(:text) { "See http://github.com/atech/postal!" }

      it "tracks the URL" do
        expect(parser.tracked_links).to eq 1
      end
    end

    context "with a bare URL inside HTML-looking text" do
      let(:text) { %(<a href="http://github.com/x">http://github.com/x</a>) }

      it "only rewrites URLs that are followed by whitespace or end of line" do
        expect(parser.tracked_links).to eq 0
        expect(text_body).to include(text)
      end
    end

    context "with non-ASCII text around the URL" do
      let(:text) { "Grüße! http://github.com/atech/postal – danke" }

      it "tracks the URL and keeps the surrounding text" do
        expect(parser.tracked_links).to eq 1
        expect(text_body).to include("Grüße!")
        expect(text_body).to include("– danke")
      end
    end
  end

  describe "excluded click domains" do
    let(:message) { create_plain_text_message(server, text, "test@example.com") }
    let(:domain) { message.domain }
    let(:parser) { Postal::MessageParser.new(message) }
    let(:text_body) { reparse(parser).text_part.decoded }

    context "with an exact domain match" do
      let(:text) { "http://github.com/atech/postal" }

      before { create(:track_domain, server: server, domain: domain, excluded_click_domains: "github.com") }

      it "does not track the link" do
        expect(parser.tracked_links).to eq 0
        expect(parser.actioned?).to be false
        expect(links_for(message)).to be_empty
        expect(text_body).to include(text)
      end
    end

    context "with a sub-domain of an excluded domain" do
      let(:text) { "http://www.github.com/atech/postal" }

      before { create(:track_domain, server: server, domain: domain, excluded_click_domains: "github.com") }

      it "still tracks the link because exclusions are exact matches" do
        expect(parser.tracked_links).to eq 1
      end
    end

    context "with an excluded domain on a non-standard port" do
      let(:text) { "http://github.com:8080/atech/postal" }

      before { create(:track_domain, server: server, domain: domain, excluded_click_domains: "github.com") }

      it "still tracks the link because the port is part of the domain capture" do
        expect(parser.tracked_links).to eq 1
      end
    end

    context "with an excluded domain followed by a full stop" do
      let(:text) { "Visit http://github.com." }

      before { create(:track_domain, server: server, domain: domain, excluded_click_domains: "github.com") }

      it "does not track the link" do
        expect(parser.tracked_links).to eq 0
      end
    end

    context "with several excluded domains" do
      let(:text) { "http://github.com/a http://example.org/b http://other.net/c" }

      before { create(:track_domain, server: server, domain: domain, excluded_click_domains: "github.com\n  example.org  \r\n") }

      it "excludes every listed domain and ignores surrounding whitespace" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://other.net/c"
        expect(text_body).to include("http://github.com/a")
        expect(text_body).to include("http://example.org/b")
      end
    end

    context "in HTML parts" do
      let(:html_domain) { create(:domain, owner: server) }
      let(:message) { create_html_message(server, html_domain, %(<a href="https://github.com/x">a</a> <a href="https://example.org/y">b</a>)) }

      before { create(:track_domain, server: server, domain: html_domain, excluded_click_domains: "github.com", track_loads: false) }

      it "only rewrites links for non-excluded domains" do
        html = reparse(parser).html_part.decoded
        expect(parser.tracked_links).to eq 1
        expect(html).to include(%(href="https://github.com/x"))
        expect(html).to match(/href='https:\/\/click\.#{Regexp.escape(html_domain.name)}\//)
        expect(links_for(message).first["url"]).to eq "https://example.org/y"
      end
    end
  end

  describe "+notrack markers" do
    let(:message) { create_plain_text_message(server, text, "test@example.com") }
    let(:domain) { message.domain }
    let(:parser) { Postal::MessageParser.new(message) }
    let(:text_body) { reparse(parser).text_part.decoded }

    before { create(:track_domain, server: server, domain: domain) }

    context "with http+notrack" do
      let(:text) { "http+notrack://github.com/atech/postal" }

      it "strips the marker without tracking the link" do
        expect(parser.tracked_links).to eq 0
        expect(parser.actioned?).to be true
        expect(text_body).to include("http://github.com/atech/postal")
        expect(text_body).not_to include("+notrack")
      end
    end

    context "with https+notrack" do
      let(:text) { "https+notrack://github.com/atech/postal" }

      it "strips the marker and keeps the https protocol" do
        expect(parser.tracked_links).to eq 0
        expect(text_body).to include("https://github.com/atech/postal")
        expect(text_body).not_to include("+notrack")
      end
    end

    context "with an upper-case protocol" do
      let(:text) { "HTTP+notrack://github.com/atech/postal" }

      it "leaves the marker in place" do
        expect(parser.actioned?).to be false
        expect(text_body).to include(text)
      end
    end

    context "with a non-http protocol" do
      let(:text) { "ftp+notrack://github.com/atech/postal" }

      it "leaves the marker in place" do
        expect(parser.actioned?).to be false
        expect(text_body).to include(text)
      end
    end

    context "with a mixture of tracked and untracked links" do
      let(:text) { "http://github.com/tracked and http+notrack://github.com/untracked" }

      it "only tracks the link without the marker" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://github.com/tracked"
        expect(text_body).to include("http://github.com/untracked")
      end
    end

    context "with several markers" do
      let(:text) { "http+notrack://a.com/x https+notrack://b.com/y" }

      it "strips all of them" do
        expect(text_body).to include("http://a.com/x https://b.com/y")
      end
    end

    context "when click tracking is disabled" do
      let(:text) { "http+notrack://github.com/atech/postal" }

      before { server.track_domains.first.update!(track_clicks: false) }

      it "still strips the marker" do
        expect(parser.actioned?).to be true
        expect(text_body).to include("http://github.com/atech/postal")
      end
    end

    context "in HTML parts" do
      let(:html_domain) { create(:domain, owner: server) }
      let(:message) { create_html_message(server, html_domain, %(<a href="http+notrack://github.com/x">a</a><a href='https+notrack://github.com/y'>b</a>)) }

      it "strips the markers without tracking the links" do
        html = reparse(parser).html_part.decoded
        expect(parser.tracked_links).to eq 0
        expect(parser.actioned?).to be true
        expect(html).to include(%(href="http://github.com/x"))
        expect(html).to include(%(href='https://github.com/y'))
      end
    end
  end

  describe "HTML link rewriting" do
    let(:domain) { create(:domain, owner: server) }
    let(:message) { create_html_message(server, domain, html) }
    let(:parser) { Postal::MessageParser.new(message) }
    let(:html_body) { reparse(parser).html_part.decoded }
    let(:href_regex) { /href='https:\/\/click\.#{Regexp.escape(domain.name)}\/#{server.token}\/[A-Za-z0-9]{16}'/ }

    before { create(:track_domain, server: server, domain: domain, track_loads: false) }

    context "with a double-quoted href" do
      let(:html) { %(<a href="https://github.com/atech/postal">Postal</a>) }

      it "rewrites the href using single quotes" do
        expect(parser.tracked_links).to eq 1
        expect(html_body).to match(href_regex)
        expect(html_body).to include(">Postal</a>")
        expect(html_body).not_to include("github.com")
      end

      it "stores the original URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "https://github.com/atech/postal"
      end
    end

    context "with a single-quoted href" do
      let(:html) { %(<a href='https://github.com/atech/postal'>Postal</a>) }

      it "rewrites the href" do
        expect(parser.tracked_links).to eq 1
        expect(html_body).to match(href_regex)
      end
    end

    context "with mismatched quotes" do
      let(:html) { %(<a href="https://github.com/atech/postal'>Postal</a>) }

      it "still rewrites the href" do
        expect(parser.tracked_links).to eq 1
        expect(html_body).to match(href_regex)
      end
    end

    context "with whitespace around the equals sign" do
      let(:html) { %(<a href = "https://github.com/atech/postal">Postal</a>) }

      it "does not rewrite the href" do
        expect(parser.tracked_links).to eq 0
        expect(html_body).to include(html)
      end
    end

    context "with an upper-case attribute name" do
      let(:html) { %(<a HREF="https://github.com/atech/postal">Postal</a>) }

      it "does not rewrite the href" do
        expect(parser.tracked_links).to eq 0
        expect(html_body).to include(html)
      end
    end

    context "with an upper-case protocol" do
      let(:html) { %(<a href="HTTPS://github.com/atech/postal">Postal</a>) }

      it "does not rewrite the href" do
        expect(parser.tracked_links).to eq 0
        expect(html_body).to include(html)
      end
    end

    context "with a bare URL in text" do
      let(:html) { "<p>https://github.com/atech/postal</p>" }

      it "does not rewrite the URL" do
        expect(parser.tracked_links).to eq 0
        expect(html_body).to include(html)
      end
    end

    context "with URLs in other attributes" do
      let(:html) { %(<img src="https://github.com/logo.png"><a href="https://github.com/x" title="https://github.com/y">x</a>) }

      it "only rewrites the href" do
        expect(parser.tracked_links).to eq 1
        expect(html_body).to include(%(src="https://github.com/logo.png"))
        expect(html_body).to include(%(title="https://github.com/y"))
        expect(links_for(message).first["url"]).to eq "https://github.com/x"
      end
    end

    context "with a data-href attribute" do
      let(:html) { %(<div data-href="https://github.com/x">x</div>) }

      it "rewrites it because the pattern isn't anchored to a word boundary" do
        expect(parser.tracked_links).to eq 1
        expect(html_body).to match(/data-#{href_regex}/)
      end
    end

    context "with HTML-escaped ampersands" do
      let(:html) { %(<a href="https://github.com/search?q=1&amp;page=2">x</a>) }

      it "stores the unescaped URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "https://github.com/search?q=1&page=2"
      end
    end

    context "with a query string, fragment and port" do
      let(:html) { %(<a href="https://github.com:8443/search?q=postal&page=2#top">x</a>) }

      it "stores the complete URL" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "https://github.com:8443/search?q=postal&page=2#top"
      end
    end

    context "with balanced parentheses in the path" do
      let(:html) { %(<a href="https://en.wikipedia.org/wiki/Foo_(bar)">x</a>) }

      it "stores the complete URL without trimming" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "https://en.wikipedia.org/wiki/Foo_(bar)"
      end
    end

    context "with a trailing slash" do
      let(:html) { %(<a href="https://github.com/atech/">x</a>) }

      it "stores the URL without trimming the slash" do
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "https://github.com/atech/"
      end
    end

    context "with a comma in the URL" do
      let(:html) { %(<a href="https://github.com/a,b">x</a>) }

      it "does not rewrite the href" do
        expect(parser.tracked_links).to eq 0
        expect(html_body).to include(html)
      end
    end

    context "with a space in the URL" do
      let(:html) { %(<a href="https://github.com/a b">x</a>) }

      it "does not rewrite the href" do
        expect(parser.tracked_links).to eq 0
        expect(html_body).to include(html)
      end
    end

    context "with an IPv6 host" do
      let(:html) { %(<a href="http://[::1]/x">x</a>) }

      it "does not rewrite the href" do
        expect(parser.tracked_links).to eq 0
        expect(html_body).to include(html)
      end
    end

    context "with userinfo in the URL" do
      let(:html) { %(<a href="https://user:pw@github.com/x">x</a>) }

      it "does not rewrite the href" do
        expect(parser.tracked_links).to eq 0
        expect(html_body).to include(html)
      end
    end

    context "with non-http hrefs" do
      let(:html) { %(<a href="mailto:a@b.com">m</a><a href="#top">t</a><a href="/relative">r</a><a href="//github.com/x">p</a><a href="ftp://github.com/x">f</a>) }

      it "leaves them untouched" do
        expect(parser.tracked_links).to eq 0
        expect(html_body).to include(html)
      end
    end

    context "with several links" do
      let(:html) { %(<a href="https://github.com/one">1</a><a href='http://github.com/two'>2</a><a href="https://github.com/one">3</a>) }

      it "rewrites each with a distinct token" do
        expect(parser.tracked_links).to eq 3
        expect(html_body.scan(href_regex).size).to eq 3
        tokens = html_body.scan(/\/#{server.token}\/([A-Za-z0-9]{16})'/).flatten
        expect(tokens.uniq.size).to eq 3
        expect(links_for(message).map { |l| l["url"] }).to contain_exactly("https://github.com/one", "http://github.com/two", "https://github.com/one")
      end
    end

    context "with a href on its own line inside the tag" do
      let(:html) { %(<a\n  href="https://github.com/x"\n  class="btn">x</a>) }

      it "rewrites the href" do
        expect(parser.tracked_links).to eq 1
        expect(html_body).to include(%(class="btn"))
      end
    end
  end

  describe "tracking image insertion" do
    let(:domain) { create(:domain, owner: server) }
    let(:message) { create_html_message(server, domain, html) }
    let(:parser) { Postal::MessageParser.new(message) }
    let(:html_body) { reparse(parser).html_part.decoded }
    let(:image_regex) { /<p class='ampimg'[^>]*><img src='https:\/\/click\.#{Regexp.escape(domain.name)}\/img\/#{server.token}\/#{message.token}' alt=''><\/p>/ }

    before { create(:track_domain, server: server, domain: domain, track_clicks: false) }

    context "with a closing body tag" do
      let(:html) { "<html><body><p>Hi</p></body></html>" }

      it "inserts the image immediately before </body>" do
        expect(parser.tracked_images).to eq 1
        expect(parser.actioned?).to be true
        expect(html_body).to match(/<p>Hi<\/p>#{image_regex}<\/body><\/html>/)
        expect(html_body.scan("ampimg").size).to eq 1
      end
    end

    context "without a closing body tag" do
      let(:html) { "<p>Hi</p>" }

      it "appends the image to the end of the part" do
        expect(parser.tracked_images).to eq 1
        expect(html_body).to match(/<p>Hi<\/p>#{image_regex}\s*\z/)
      end
    end

    context "with an upper-case closing body tag" do
      let(:html) { "<HTML><BODY><p>Hi</p></BODY></HTML>" }

      it "appends the image to the end because the match is case-sensitive" do
        expect(parser.tracked_images).to eq 1
        expect(html_body).to match(/<\/BODY><\/HTML>#{image_regex}\s*\z/)
      end
    end

    context "with whitespace inside the closing body tag" do
      let(:html) { "<body><p>Hi</p></body >" }

      it "appends the image to the end" do
        expect(parser.tracked_images).to eq 1
        expect(html_body).to match(/<\/body >#{image_regex}\s*\z/)
      end
    end

    context "with several closing body tags" do
      let(:html) { "<body>a</body><body>b</body>" }

      it "inserts an image before each one but counts a single tracked image" do
        expect(parser.tracked_images).to eq 1
        expect(html_body.scan("ampimg").size).to eq 2
      end
    end

    context "when load tracking is disabled" do
      let(:html) { "<body>Hi</body>" }

      before { server.track_domains.first.update!(track_loads: false) }

      it "does not insert an image" do
        expect(parser.tracked_images).to eq 0
        expect(parser.actioned?).to be false
        expect(html_body).not_to include("ampimg")
      end
    end

    context "with a plain text part" do
      let(:message) { create_plain_text_message(server, "Hello </body>", "test@example.com") }

      before { create(:track_domain, server: server, domain: message.domain, track_clicks: false) }

      it "does not insert an image into text parts" do
        expect(parser.tracked_images).to eq 0
        expect(reparse(parser).text_part.decoded).to include("Hello </body>")
      end
    end

    context "when the track domain does not use SSL" do
      let(:html) { "<body>Hi</body>" }

      before { server.track_domains.first.update!(ssl_enabled: false) }

      it "uses an http image URL" do
        expect(parser.tracked_images).to eq 1
        expect(html_body).to include("<img src='http://click.#{domain.name}/img/#{server.token}/#{message.token}'")
      end
    end
  end

  describe "mime type matching and part recursion" do
    let(:domain) { create(:domain, owner: server) }
    let(:parser) { Postal::MessageParser.new(message) }

    before { create(:track_domain, server: server, domain: domain) }

    context "with a single-part text/plain message" do
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.body = "Plain http://github.com/atech/postal"
        end
      end

      it "rewrites links in the body" do
        expect(message.raw_message).to match(/Content-Type: text\/plain/)
        expect(parser.tracked_links).to eq 1
        expect(parser.tracked_images).to eq 0
        expect(reparse(parser).body.decoded).to match(/Plain #{tracked_url_regex(domain, server)}/)
      end
    end

    context "with a single-part text/html message" do
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.content_type = "text/html; charset=UTF-8"
          mail.body = %(<body><a href="http://github.com/x">x</a></body>)
        end
      end

      it "rewrites links and inserts the tracking image" do
        expect(parser.tracked_links).to eq 1
        expect(parser.tracked_images).to eq 1
        body = reparse(parser).body.decoded
        expect(body).to include("href='https://click.#{domain.name}/")
        expect(body).to match(/ampimg.*<\/body>/)
      end
    end

    context "with a single-part message of another text type" do
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.content_type = "text/calendar; charset=UTF-8"
          mail.body = "URL:http://github.com/atech/postal"
        end
      end

      it "leaves the body untouched" do
        expect(parser.actioned?).to be false
        expect(parser.tracked_links).to eq 0
        expect(reparse(parser).body.decoded).to include("URL:http://github.com/atech/postal")
      end
    end

    context "with a single-part non-text message" do
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.content_type = "application/json"
          mail.body = %({"url":"http://github.com/atech/postal"})
        end
      end

      it "leaves the body untouched" do
        expect(parser.actioned?).to be false
        expect(reparse(parser).body.decoded).to include("http://github.com/atech/postal")
      end
    end

    context "with multipart/alternative text and html parts" do
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.body = ""
          mail.text_part = Mail::Part.new do
            content_type "text/plain; charset=UTF-8"
            body "Text http://github.com/text"
          end
          mail.html_part = Mail::Part.new do
            content_type "text/html; charset=UTF-8"
            body %(<body><a href="http://github.com/html">x</a></body>)
          end
        end
      end

      it "rewrites both parts and only inserts an image into the html part" do
        expect(parser.tracked_links).to eq 2
        expect(parser.tracked_images).to eq 1
        mail = reparse(parser)
        expect(mail.text_part.decoded).to match(/Text #{tracked_url_regex(domain, server)}/)
        expect(mail.text_part.decoded).not_to include("ampimg")
        expect(mail.html_part.decoded).to include("ampimg")
        expect(links_for(message).map { |l| l["url"] }).to contain_exactly("http://github.com/text", "http://github.com/html")
      end
    end

    context "with html nested in multipart/mixed > multipart/alternative > multipart/related" do
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.body = ""
          mail.content_type = "multipart/mixed"
          related = Mail::Part.new
          related.content_type = "multipart/related"
          related.add_part(Mail::Part.new do
            content_type "text/html; charset=UTF-8"
            body %(<body><a href="http://github.com/nested">x</a></body>)
          end)
          alternative = Mail::Part.new
          alternative.content_type = "multipart/alternative"
          alternative.add_part(Mail::Part.new do
            content_type "text/plain; charset=UTF-8"
            body "Text http://github.com/text"
          end)
          alternative.add_part(related)
          mail.add_part(alternative)
        end
      end

      it "recurses into the nested parts" do
        expect(parser.tracked_links).to eq 2
        expect(parser.tracked_images).to eq 1
        mail = reparse(parser)
        expect(mail.html_part.decoded).to include("href='https://click.#{domain.name}/")
        expect(mail.html_part.decoded).to include("ampimg")
        expect(mail.text_part.decoded).to match(tracked_url_regex(domain, server))
      end
    end

    context "with html nested inside a multipart/mixed sub-part" do
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.body = ""
          mail.content_type = "multipart/mixed"
          inner = Mail::Part.new
          inner.content_type = "multipart/mixed"
          inner.add_part(Mail::Part.new do
            content_type "text/html; charset=UTF-8"
            body %(<body><a href="http://github.com/nested">x</a></body>)
          end)
          mail.add_part(inner)
        end
      end

      it "does not recurse because only alternative and related sub-parts are followed" do
        expect(parser.actioned?).to be false
        expect(parser.tracked_links).to eq 0
        expect(parser.tracked_images).to eq 0
        expect(reparse(parser).html_part.decoded).to include(%(href="http://github.com/nested"))
      end
    end

    context "with a text/plain attachment" do
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.add_file(filename: "notes.txt", content: "see http://github.com/notes")
        end
      end

      it "rewrites links inside the attachment because it matches text/plain" do
        expect(message.raw_message).to include("Content-Disposition: attachment")
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://github.com/notes"
        expect(reparse(parser).attachments.first.decoded).to match(/see #{tracked_url_regex(domain, server)}/)
      end
    end

    context "with a binary attachment" do
      let(:pdf) { "%PDF-1.4 http://github.com/x \x00\x01\xFF".b }
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.html_part = Mail::Part.new do
            content_type "text/html; charset=UTF-8"
            body %(<body><a href="http://github.com/x">x</a></body>)
          end
          mail.attachments["file.pdf"] = { mime_type: "application/pdf", content: pdf }
        end
      end

      it "leaves the attachment untouched while rewriting the html part" do
        expect(parser.tracked_links).to eq 1
        attachment = reparse(parser).attachments.first
        expect(attachment.content_type).to include("application/pdf")
        expect(attachment.decoded.b).to eq pdf
      end
    end

    context "with a quoted-printable text part" do
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.body = ""
          headers = "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable"
          mail.text_part = Mail::Part.new("#{headers}\r\n\r\nVisit http://github.com/atech/postal?a=3D1&b=3D2 now =C3=BC\r\n")
        end
      end

      it "decodes the part before rewriting links" do
        expect(message.raw_message).to include("quoted-printable")
        expect(message.raw_message).to include("a=3D1&b=3D2")
        expect(parser.tracked_links).to eq 1
        expect(links_for(message).first["url"]).to eq "http://github.com/atech/postal?a=1&b=2"
        expect(reparse(parser).text_part.decoded).to match(/Visit #{tracked_url_regex(domain, server)} now ü/)
      end
    end

    context "with a base64 html part" do
      let(:html) { %(<html><body><a href="http://github.com/atech/postal">x</a></body></html>) }
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.body = ""
          mail.html_part = Mail::Part.new("Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n#{Base64.strict_encode64(html)}\r\n")
        end
      end

      it "decodes the part before rewriting links and inserting the image" do
        expect(message.raw_message).to include("base64")
        expect(message.raw_message).not_to include("github.com")
        expect(parser.tracked_links).to eq 1
        expect(parser.tracked_images).to eq 1
        decoded = reparse(parser).html_part.decoded
        expect(decoded).to include("href='https://click.#{domain.name}/")
        expect(decoded).to match(/ampimg.*<\/body><\/html>/)
      end
    end

    context "with a non-UTF-8 charset on the text part" do
      let(:message) do
        MessageFactory.outgoing(server, domain: domain) do |_msg, mail|
          mail.body = ""
          mail.text_part = Mail::Part.new("Content-Type: text/plain; charset=ISO-8859-1\r\nContent-Transfer-Encoding: 8bit\r\n\r\nCaf\xE9 http://github.com/x\r\n".b)
        end
      end

      it "re-labels the rewritten part as UTF-8" do
        expect(parser.tracked_links).to eq 1
        part = reparse(parser).text_part
        expect(part.charset).to eq "UTF-8"
        expect(part.decoded).to match(tracked_url_regex(domain, server))
      end
    end

    context "when the track domain belongs to a different domain" do
      let(:other_domain) { create(:domain, owner: server) }
      let(:message) { create_html_message(server, other_domain, %(<a href="http://github.com/x">x</a>)) }

      it "does nothing" do
        expect(server.track_domains.size).to eq 1
        expect(parser.actioned?).to be false
        expect(parser.tracked_links).to eq 0
        expect(parser.tracked_images).to eq 0
      end
    end
  end
end

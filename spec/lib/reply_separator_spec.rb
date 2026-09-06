# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReplySeparator do
  subject(:result) { described_class.separate(text) }

  let(:body) { result[0] }
  let(:stripped) { result[1] }

  describe "input handling" do
    it "returns an empty string for nil" do
      expect(described_class.separate(nil)).to eq ""
    end

    it "returns an empty string for non-string input" do
      expect(described_class.separate(123)).to eq ""
    end

    context "with an empty string" do
      let(:text) { "" }

      it "returns an empty body and no stripped text" do
        expect(body).to eq ""
        expect(stripped).to be_nil
      end
    end

    context "with no separators" do
      let(:text) { "  Hello,\n\nJust checking in.\n\n" }

      it "returns the stripped body and nil" do
        expect(body).to eq "Hello,\n\nJust checking in."
        expect(stripped).to be_nil
      end
    end

    context "with CRLF line endings" do
      let(:text) { "Hello\r\n\r\n-- \r\nJohn\r\n" }

      it "normalises to LF before separating" do
        expect(body).to eq "Hello"
        expect(stripped).to eq "-- \nJohn"
      end
    end
  end

  describe "signature delimiter" do
    context "with a standard '-- ' delimiter" do
      let(:text) { "Hello\n\n-- \nJohn Smith\nCEO\n" }

      it "strips the signature" do
        expect(body).to eq "Hello"
        expect(stripped).to eq "-- \nJohn Smith\nCEO"
      end
    end

    context "with ten dashes" do
      let(:text) { "Hello\n\n---------- \nJohn\n" }

      it "strips the signature" do
        expect(body).to eq "Hello"
        expect(stripped).to eq "---------- \nJohn"
      end
    end

    context "with eleven dashes" do
      let(:text) { "Hello\n\n----------- \nJohn\n" }

      it "does not strip anything" do
        expect(body).to eq text.strip
        expect(stripped).to be_nil
      end
    end

    context "with a single dash" do
      let(:text) { "Hello\n\n- \nJohn\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "without the trailing space" do
      let(:text) { "Hello\n\n--\nJohn\n" }

      it "does not strip anything" do
        expect(body).to eq "Hello\n\n--\nJohn"
        expect(stripped).to be_nil
      end
    end

    context "with two trailing spaces" do
      let(:text) { "Hello\n\n--  \nJohn\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "when the delimiter is not at the start of a line" do
      let(:text) { "Hello -- \nJohn\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "with a quoted reply after the signature" do
      let(:text) { "Hello\n\n-- \nJohn\n\n> Old message\n" }

      it "strips everything after the delimiter" do
        expect(body).to eq "Hello"
        expect(stripped).to eq "-- \nJohn\n\n> Old message"
      end
    end
  end

  describe "Outlook original message separator" do
    context "with the standard header" do
      let(:text) { "Thanks\n\n-----Original Message-----\nFrom: John\nSent: Monday\n\nOld body\n" }

      it "strips the header and everything after it" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "-----Original Message-----\nFrom: John\nSent: Monday\n\nOld body"
      end
    end

    context "with spaces inside the dashes" do
      let(:text) { "Thanks\n\n----- Original Message -----\nOld body\n" }

      it "strips the header" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "----- Original Message -----\nOld body"
      end
    end

    context "when quoted with '>'" do
      let(:text) { "Thanks\n\n> -----Original Message-----\n> Old body\n" }

      it "strips the quoted header" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "> -----Original Message-----\n> Old body"
      end
    end

    context "when quoted with several '>' and indentation" do
      let(:text) { "Thanks\n\n>>   -----Original Message-----\n>> Old body\n" }

      it "strips the quoted header" do
        expect(body).to eq "Thanks"
        expect(stripped).to start_with(">>   -----Original Message-----")
      end
    end

    context "with different casing" do
      let(:text) { "Thanks\n\n-----original message-----\nOld body\n" }

      it "does not match because the rule is case-sensitive" do
        expect(stripped).to be_nil
      end
    end

    context "with fewer than five dashes" do
      let(:text) { "Thanks\n\n---Original Message---\nOld body\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end
  end

  describe "Outlook From/Sent header block" do
    context "with Sent: immediately after From:" do
      let(:text) { "Thanks\n\nFrom: John <john@example.com>\nSent: Monday 1 January\nTo: Jane\nSubject: Hi\n\nOld body\n" }

      it "strips the header block and everything after it" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "From: John <john@example.com>\nSent: Monday 1 January\nTo: Jane\nSubject: Hi\n\nOld body"
      end
    end

    context "with a blank line between From: and Sent:" do
      let(:text) { "Thanks\n\nFrom: John\n\nSent: Monday\n" }

      it "strips the header block" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "From: John\n\nSent: Monday"
      end
    end

    context "with another header between From: and Sent:" do
      let(:text) { "Thanks\n\nFrom: John\nTo: Jane\nSent: Monday\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "when quoted" do
      let(:text) { "Thanks\n\n> From: John\n> Sent: Monday\n" }

      it "strips the quoted block" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "> From: John\n> Sent: Monday"
      end
    end

    context "with From: in the middle of a line" do
      let(:text) { "Message From: John\nSent: Monday\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end
  end

  describe "Outlook From/Date header block" do
    context "with Date: immediately after From:" do
      let(:text) { "Thanks\n\nFrom: John\nDate: Monday\nSubject: Hi\n" }

      it "strips the header block" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "From: John\nDate: Monday\nSubject: Hi"
      end
    end

    context "with another header between From: and Date:" do
      let(:text) { "Thanks\n\nFrom: John\nTo: Jane\nDate: Monday\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end
  end

  describe "German Outlook separator" do
    context "with a trailing space after the dashes" do
      let(:text) { "Danke\n\n-----Ursprüngliche Nachricht----- \nVon: Hans\n" }

      it "strips the header" do
        expect(body).to eq "Danke"
        expect(stripped).to eq "-----Ursprüngliche Nachricht----- \nVon: Hans"
      end
    end

    context "with an ASCII u" do
      let(:text) { "Danke\n\n-----Ursprungliche Nachricht----- \nVon: Hans\n" }

      it "strips the header because the umlaut position is a wildcard" do
        expect(body).to eq "Danke"
      end
    end

    context "without a trailing space after the dashes" do
      let(:text) { "Danke\n\n-----Ursprüngliche Nachricht-----\nVon: Hans\n" }

      it "strips the header" do
        expect(body).to eq "Danke"
        expect(stripped).to eq "-----Ursprüngliche Nachricht-----\nVon: Hans"
      end
    end
  end

  describe "French separator" do
    context "with a typical Apple Mail header" do
      let(:text) { "Bonjour\n\nLe 12 mars 2024 à 10:00, Jean Dupont <jean@example.fr> a écrit :\n\n> Ligne 1\n> Ligne 2\n" }

      it "strips the header line and the quoted lines that follow" do
        expect(stripped).to eq "Le 12 mars 2024 à 10:00, Jean Dupont <jean@example.fr> a écrit :\n\n> Ligne 1\n> Ligne 2"
        expect(body).to eq "Bonjour"
      end
    end

    context "without a space before the colon" do
      let(:text) { "Bonjour\n\nLe 12 mars 2024 à 10:00, Jean a écrit:\n" }

      it "strips the header line" do
        expect(body).to eq "Bonjour"
        expect(stripped).to eq "Le 12 mars 2024 à 10:00, Jean a écrit:"
      end
    end

    context "when quoted" do
      let(:text) { "Bonjour\n\n> Le 12 mars 2024 à 10:00, Jean a écrit :\n" }

      it "strips the quoted header line" do
        expect(body).to eq "Bonjour"
        expect(stripped).to eq "> Le 12 mars 2024 à 10:00, Jean a écrit :"
      end
    end

    context "with too little text between Le and a écrit" do
      let(:text) { "Bonjour\n\nLe 12 a écrit :\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "when text follows the colon" do
      let(:text) { "Bonjour\n\nLe 12 mars 2024 à 10:00, Jean a écrit : bonjour\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end
  end

  describe "underscore separator" do
    context "with eighteen underscores" do
      let(:text) { "Thanks\n\n#{'_' * 18}\nFrom: John\n" }

      it "strips the separator and everything after it" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "#{'_' * 18}\nFrom: John"
      end
    end

    context "with more than eighteen underscores" do
      let(:text) { "Thanks\n\n#{'_' * 40}\nFrom: John\n" }

      it "strips the separator" do
        expect(body).to eq "Thanks"
      end
    end

    context "with fewer than eighteen underscores" do
      let(:text) { "Thanks\n\n#{'_' * 17}\nFrom: John\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "when quoted" do
      let(:text) { "Thanks\n\n> #{'_' * 18}\n> From: John\n" }

      it "strips the quoted separator" do
        expect(body).to eq "Thanks"
      end
    end
  end

  describe "Gmail style 'On ... wrote:' header" do
    context "with a single-line header" do
      let(:text) { "Thanks!\n\nOn Mon, Jan 1, 2024 at 10:00 AM John Smith <john@example.com> wrote:\n\n> Hello\n> World\n" }

      it "strips the header and the quoted text" do
        expect(body).to eq "Thanks!"
        expect(stripped).to eq "On Mon, Jan 1, 2024 at 10:00 AM John Smith <john@example.com> wrote:\n\n> Hello\n> World"
      end
    end

    context "with a header wrapped over two lines" do
      let(:text) { "Thanks!\n\nOn Mon, Jan 1, 2024 at 10:00 AM John Smith\n<john@example.com> wrote:\n> Hello\n" }

      it "strips the wrapped header and the quoted text" do
        expect(body).to eq "Thanks!"
        expect(stripped).to eq "On Mon, Jan 1, 2024 at 10:00 AM John Smith\n<john@example.com> wrote:\n> Hello"
      end
    end

    context "with an Apple Mail style header" do
      let(:text) { "Thanks!\n\nOn 1 Jan 2024, at 10:00, John Smith <john@example.com> wrote:\n\n> Hello\n" }

      it "strips the header and the quoted text" do
        expect(body).to eq "Thanks!"
      end
    end

    context "when quoted" do
      let(:text) { "Thanks!\n\n> On Mon, Jan 1, 2024 at 10:00 AM John <john@example.com> wrote:\n> > Hello\n" }

      it "strips the quoted header" do
        expect(body).to eq "Thanks!"
        expect(stripped).to start_with("> On Mon")
      end
    end

    context "with trailing whitespace after wrote:" do
      let(:text) { "Thanks!\n\nOn Mon, Jan 1, 2024 John <john@example.com> wrote:   \n> Hello\n" }

      it "strips the header" do
        expect(body).to eq "Thanks!"
      end
    end

    context "with too little text between On and wrote:" do
      let(:text) { "Thanks!\n\nOn x wrote:\n> Hello\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "with text after wrote:" do
      let(:text) { "Thanks!\n\nOn Mon, Jan 1, 2024 John wrote: something else\n> Hello\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "with 'wrote:' but no line starting with On" do
      let(:text) { "Thanks!\n\nYesterday John <john@example.com> wrote:\n> Hello\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end
  end

  describe "'Sent from my' footer" do
    context "with an iPhone footer" do
      let(:text) { "Thanks\n\nSent from my iPhone\n" }

      it "strips the footer" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "Sent from my iPhone"
      end
    end

    context "with a footer followed by a quoted reply" do
      let(:text) { "Thanks\n\nSent from my Samsung Galaxy\n\n> Old message\n" }

      it "strips the footer and everything after it" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "Sent from my Samsung Galaxy\n\n> Old message"
      end
    end

    context "when quoted" do
      let(:text) { "Thanks\n\n> Sent from my iPad\n" }

      it "strips the quoted footer" do
        expect(body).to eq "Thanks"
      end
    end

    context "when the phrase is in the middle of a line" do
      let(:text) { "This was Sent from my desk\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "with different casing" do
      let(:text) { "Thanks\n\nsent from my iPhone\n" }

      it "does not match because the rule is case-sensitive" do
        expect(stripped).to be_nil
      end
    end
  end

  describe "'Please reply above this line' marker" do
    context "with the marker" do
      let(:text) { "My reply\n\n=== Please reply above this line ===\nTicket details\n" }

      it "strips the marker and everything after it" do
        expect(body).to eq "My reply"
        expect(stripped).to eq "=== Please reply above this line ===\nTicket details"
      end
    end

    context "when quoted" do
      let(:text) { "My reply\n\n> === Please reply above this line ===\n> Ticket details\n" }

      it "strips the quoted marker" do
        expect(body).to eq "My reply"
      end
    end

    context "with a different number of equals signs" do
      let(:text) { "My reply\n\n== Please reply above this line ==\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end
  end

  describe "long runs of quoted lines" do
    context "with ten consecutive quoted lines" do
      let(:quoted) { (1..10).map { |i| "> line #{i}" }.join("\n") }
      let(:text) { "Reply\n#{quoted}\n" }

      it "strips the quoted block" do
        expect(body).to eq "Reply"
        expect(stripped).to eq quoted
      end
    end

    context "with nine consecutive quoted lines" do
      let(:quoted) { (1..9).map { |i| "> line #{i}" }.join("\n") }
      let(:text) { "Reply\n#{quoted}\n" }

      it "does not strip anything" do
        expect(body).to eq "Reply\n#{quoted}"
        expect(stripped).to be_nil
      end
    end

    context "with ten quoted lines interrupted by a blank line" do
      let(:text) { "Reply\n#{(['> a'] * 5).join("\n")}\n\n#{(['> b'] * 5).join("\n")}\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "with ten quoted lines interrupted by an unquoted line" do
      let(:text) { "Reply\n#{(['> a'] * 5).join("\n")}\nme\n#{(['> b'] * 5).join("\n")}\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end

    context "with more than ten quoted lines using nested quoting" do
      let(:quoted) { (1..12).map { |i| ">> nested #{i}" }.join("\n") }
      let(:text) { "Reply\n\n#{quoted}\n\nAfter\n" }

      it "strips only the quoted block" do
        expect(body).to eq "Reply\n\n\nAfter"
        expect(stripped).to eq quoted
      end
    end

    context "with ten lines that contain but do not start with '>'" do
      let(:text) { "Reply\n#{(['a > b'] * 10).join("\n")}\n" }

      it "does not strip anything" do
        expect(stripped).to be_nil
      end
    end
  end

  describe "combining several separators" do
    context "with a mobile footer followed by a signature" do
      let(:text) { "Thanks\n\nSent from my iPhone\n\n-- \nJohn\n" }

      it "strips both and reports later rules first" do
        expect(body).to eq "Thanks"
        expect(stripped).to start_with("Sent from my iPhone")
        expect(stripped).to end_with("-- \nJohn")
      end
    end

    context "with a signature followed by a Gmail quote" do
      let(:text) { "Thanks\n\n-- \nJohn\n\nOn Mon, Jan 1, 2024 at 10:00 AM Jane <jane@example.com> wrote:\n> Hi\n" }

      it "attributes everything after the signature to the signature rule" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "-- \nJohn\n\nOn Mon, Jan 1, 2024 at 10:00 AM Jane <jane@example.com> wrote:\n> Hi"
      end
    end

    context "with two matches for the same rule" do
      let(:text) { "Thanks\n\nSent from my iPhone\nmore\nSent from my iPad\n" }

      it "strips from the first match onwards" do
        expect(body).to eq "Thanks"
        expect(stripped).to eq "Sent from my iPhone\nmore\nSent from my iPad"
      end
    end

    context "with a separator on the first line" do
      let(:text) { "-----Original Message-----\nFrom: John\n" }

      it "returns an empty body" do
        expect(body).to eq ""
        expect(stripped).to eq "-----Original Message-----\nFrom: John"
      end
    end
  end
end

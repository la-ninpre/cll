require 'nokogiri'
require 'yaml'
require 'byebug'

mydir=File.expand_path(File.dirname(__FILE__))
require "#{mydir}/util.rb"

#**************************************************
# FUNCTIONS
#**************************************************

# Splits a node's text up by words into table columns
#
# The reason this gets complicated is things like:
#
#     <gloss>The-one-named <quote>bear</quote> [past] creates the story.</gloss>
#
# We want to break up all the bits except the quote, and still keep it all in one row.
#
def table_row_by_words node
  newchildren = []
  node.children.each do |child|
    if child.text?
      words = child.text.gsub('--',"\u00A0").split( %r{\s+} )
      # Hide ellipses for now
      words.delete('…')
      words.each_index do |word_index|
        word = words[word_index]
        unless word =~ %r{^\s*$}
          td = $document.parse("<td></td>").first
          td.content = word

          # Handle word-hyphen-quote, i.e.: lerfu-<quote>c</quote>,
          # which should stay together
          if word_index == words.length-1 && word[-1] == "-" && child.next && !(child.next.text?) && child.next.element? && child.next.name == 'quote'
            td << child.next.dup
            # Skip processing the quote since we just included it
            child.next['skip'] = 'true'
          end
          newchildren << td
        end
      end
    elsif child.element? and child['skip'] != 'true'
      newchildren << $document.parse("<td>#{child}</td>").first
    end
  end
  newnode = node.replace( "<tr class='#{node.name}'></tr>" ).first
  newnode.children = Nokogiri::XML::NodeSet.new( $document, newchildren )

  return newnode
end

# Add index information ; put the index entry element as the first
# child of this node
def indexify!( node:, indextype:, role: nil )
  if role == nil
    role = node.name
  end
  node.children.first.add_previous_sibling %Q{<indexterm type="#{indextype}"><primary role="#{role}">#{node.text}</primary></indexterm>}
  return node
end

# Converts a node's name and sets the role (to the old name by
# default), with an optional language
def convert!( node:, newname:, role: nil, lang: nil )
  unless role
    role = node.name
  end
  if lang
    node['xml:lang'] = lang
  end
  if ['tr', 'td'].include? newname
    node['class'] = role
  else
    node['role'] = role
  end
  node.name = newname
  node
end

# Loops over the children of a node, complaining if a bad child is
# found and handling non-element children.
def handle_children( node:, allowed_children_names:, ignore_others: false, &proc )
  node.children.each do |child|
    unless child.element?
      next
    end

    if ! allowed_children_names.include?( child.name )
      if ignore_others
        next
      else
        abort "Found a bad element, #{child.name}, as a child of #{node.name}.  Context: #{node.to_xml}"
      end
    end

    yield child
  end
end

# Wrap node in a glossary entry
def glossify node, orignode
  $stderr.puts "glosscheck: #{orignode} -- #{orignode['glossary']} -- #{orignode['valid']}"
  if orignode['glossary'] == 'false' or orignode['valid'] == 'false'
    return node
  else
    node.replace(%Q{<glossterm linkend="valsi-#{slugify(orignode.text)}">#{node}</glossterm>})
  end
end

# Makes something into a table/informaltable with one colgroup
def tableify node

  # Convert title to caption (see
  # http://www.sagehill.net/docbookxsl/Tables.html )
  node.css("title").each { |e| convert!( node: e, newname: 'caption' ) }
  caption = node.css('caption')
  node.css('caption').remove

  # Add a colgroup and caption as the first children, to make docbook happy
  node.children.first.add_previous_sibling "#{caption}<colgroup/>"

  # Save the old name
  node['role'] = node.name
  node['class'] = node.name

  # Turn it into a table
  if node.css('caption').length > 0
    node.name = 'table'
  else
    node.name = 'informaltable'
  end

  return node
end

# Break a table into two tables; anything that matches css_string
# goes into the second table, preserving order
def table_split( node, css_string )
  if node['split'] != 'false' && node.css(css_string).length > 0 && node.css(css_string).length != node.children.length
    newnode = node.clone
    newnode.children.each do |child|
      if child.css(css_string).length == 0
        child.remove
      end
    end
    node.children.each do |child|
      if child.css(css_string).length > 0
        child.remove
      end
    end
    node.add_next_sibling newnode
  end

  node
end

#**************************************************
# MAIN CODE
#**************************************************

$document = Nokogiri::XML(File.open ARGV[0]) do |config|
  config.default_xml.noblanks
end

##      <lujvo-making>
##        <jbo>bralo'i</jbo>
##        <gloss><quote>big-boat</quote></gloss>
##        <natlang>ship</natlang>
##      </lujvo-making>
#
# Turn lujvo-making into an informaltable with one column per row
$document.css('lujvo-making').each do |node|
  # Convert children into docbook elements
  node.css('jbo,natlang,gloss').each { |e| convert!( node: e, newname: 'para' ) }
  node.css('score').each { |e| convert!( node: e, newname: 'para', role: 'lujvo-score' ) }
  node.css('inlinemath').each { |e| convert!( node: e, newname: 'mathphrase' ) ; e.replace("<inlineequation role='inlinemath'>#{e}</inlineequation>" ) }
  node.css('rafsi').each { |e| convert!( node: e, newname: 'foreignphrase', lang: 'jbo' ) }
  node.css('veljvo').each { |e| convert!( node: e, newname: 'foreignphrase', lang: 'jbo' ) ; indexify!(node: e, indextype: 'lojban-phrase') ; e.replace("<para>from #{e}</para>") }

  # Make things into rows
  node.children.each { |e| e.replace("<tr><td>#{e}</td></tr>") }

  tableify node
end

# Handle interlinear-gloss, making word-by-word tables.
#
#     <interlinear-gloss>
#       <jbo>pa re ci vo mu xa ze bi so no</jbo>
#       <gloss>one two three four five six seven eight nine zero</gloss>
#       <math>1234567890</math>
#       <natlang>one billion, two hundred and thirty-four million, five hundred and sixty-seven thousand, eight hundred and ninety.</natlang>
#       
#     </interlinear-gloss>
$document.css('interlinear-gloss').each do |node|
  unless (node.xpath('jbo').length > 0 or node.xpath('jbophrase').length > 0) and (node.xpath('natlang').length > 0 or node.xpath('gloss').length > 0 or node.xpath('math').length > 0)
    abort "Found a bad interlinear-gloss element; it must have one jbo or jbophrase sub-element and at least one gloss or natlang or math sub-element.  Context: #{node.to_xml}"
  end

  handle_children( node: node, allowed_children_names: [ 'jbo', 'jbophrase', 'gloss', 'math', 'natlang', 'para' ] ) do |child|
    if child.name == 'jbo' or child.name == 'gloss'
      table_row_by_words child
    elsif child.name == 'math'
      child.replace("<tr class='informalequation'><td colspan='0'>#{child}</td></tr>")
    else
      convert!( node: child, newname: 'para' )
      child.replace("<tr class='para'><td colspan='0'>#{child}</td></tr>")
    end
  end

  tableify node

  # If there are natlang, comment or para lines, turn it into *two* tables
  table_split( node, 'td[colspan="0"] [role=natlang],td[colspan="0"] [role=comment],td[colspan="0"] [role=para]' )
end

# handle interlinear-gloss-itemized
#
#   <interlinear-gloss-itemized>
#     <jbo>
#       <sumti>mi</sumti>
#       <elidable>cu</elidable>
#       <selbri>vecnu</selbri>
#       <sumti>ti</sumti>
#       <sumti>ta</sumti>
#       <sumti>zo'e</sumti>
#     </jbo>
#     ...
$document.css('interlinear-gloss-itemized').each do |node|
  handle_children( node: node, allowed_children_names: [ 'jbo', 'gloss', 'natlang', 'sumti', 'selbri', 'elidable', 'comment' ] ) do |child|
    if child.name == 'jbo' or child.name == 'gloss'
      handle_children( node: child, allowed_children_names: [ 'sumti', 'selbri', 'elidable', 'cmavo', 'comment' ] ) do |grandchild|
        if grandchild.name == 'elidable'
          if grandchild.text == ''
            grandchild.content = '-'
          else
            grandchild.content = "[#{grandchild.content}]"
          end
        end
        convert!( node: grandchild, newname: 'para' )
      end

      child.children.each { |e| e.replace("<td>#{e}</td>") }
      child['class'] = child.name
      child.name = 'tr'
    else
      convert!( node: child, newname: 'para' )

      child.replace("<tr class='para'><td colspan='0'>#{child}</td></tr>")
    end
  end

  tableify node

  # If there are natlang, comment or para lines, turn it into *two* tables
  table_split( node, 'td[colspan="0"] [role=natlang],td[colspan="0"] [role=comment],td[colspan="0"] [role=para]' )
end


# Math
## <natlang>Both <inlinemath>2 + 2 = 4</inlinemath> and <inlinemath>2 x 2 = 4</inlinemath>.</natlang>
$document.css('inlinemath').each { |e| convert!( node: e, newname: 'mathphrase' ) ; e.replace("<inlineequation role='inlinemath'>#{e}</inlineequation>" ) }

## <math>3:22:40 + 0:3:33 = 3:26:13</math>
$document.css('math').each { |e| convert!( node: e, newname: 'mathphrase' ) ; e.replace("<informalequation role='math'>#{e}</informalequation>" ) }

##       <pronunciation>
##         <jbo>.e'o ko ko kurji</jbo>
##         <jbo role="pronunciation">.E'o ko ko KURji</jbo>
##       </pronunciation>
##
##       <compound-cmavo>
##         <jbo>.iseci'i</jbo>
##         <jbo>.i se ci'i</jbo>
##       </compound-cmavo>
$document.css('pronunciation, compound-cmavo').each do |node|
  handle_children( node: node, allowed_children_names: [ 'jbo', 'ipa', 'natlang', 'comment' ] ) do |child|
    role = "#{node.name}-#{child.name}"
    convert!( node: child, newname: 'para', role: role )
    child.replace(%Q{<listitem role="#{role}">#{child}</listitem>}) 
  end

  convert!( node: node, newname: 'itemizedlist' )
end

## <valsi>risnyjelca</valsi> (heart burn) might have a place structure like:</para>
$document.css('valsi').each do |node|
  # We make a glossary entry unless it's marked valid=false
  if node[:valid] == 'false'
    convert!( node: node, newname: 'foreignphrase' )
  else
    orignode = node.dup
    convert!( node: node, newname: 'foreignphrase', lang: 'jbo' )
    indexify!( node: node, indextype: 'lojban-words', role: orignode.name )
    node = glossify node, orignode
    $stderr.puts "valsi: #{node.to_xml}"
  end
end

##    <simplelist>
##      <member><grammar-template>
##          X .i BAI bo Y
##      </grammar-template></member>
$document.css('grammar-template').each do |node|
  # Phrasal version
  if [ 'title', 'term', 'member', 'secondary' ].include? node.parent.name
    convert!( node: node, newname: 'phrase' )
  else
    # Block version
    convert!( node: node, newname: 'para' )
    node.replace("<blockquote role='grammar-template'>#{node}</blockquote>")
  end
end

## <para><definition><content>x1 is a nest/house/lair/den for inhabitant x2</content></definition></para>
$document.css('definition').each do |node|
  node.css('content').each do |child|
    convert!( node: child, newname: 'phrase', role: 'definition-content' )
  end
  if [ 'title', 'term', 'member', 'secondary' ].include? node.parent.name
    # Phrasal version
    convert!( node: node, newname: 'phrase' )
  else
    # Block version
    convert!( node: node, newname: 'para' )
    node.replace("<blockquote role='definition'>#{node}</blockquote>")
  end
end

# Turn it into an informaltable with maximally wide rows
$document.css('lojbanization').each do |node|
  handle_children( node: node, allowed_children_names: [ 'jbo', 'natlang' ] ) do |child|
    origname=child.name
    convert!( node: child, newname: 'para', role: child['role'] )
    child.replace("<tr class='#{origname}'><td colspan='0'>#{child}</td></tr>")
  end
  tableify node
end

$document.css('jbophrase').each do |node|
  # For now, jbophrase makes an *index* but not a *glossary*
  indexify!( node: node, indextype: 'lojban-phrase' )
  convert!( node: node, newname: 'foreignphrase', lang: 'jbo' )

  if node.parent.name == 'example'
    convert!( node: node, newname: 'para', role: 'jbophrase' )
  end
end

$document.css('cmavo-list').each do |node|
  #     Handle cmavo-list
  #
  #     <cmavo-list>
  #       <cmavo-list-head>
  #         <td>cmavo</td>
  #         <td>gismu</td>
  #         <td>comments</td>
  #       </cmavo-list-head>
  #       <title>Monosyllables of the form CVV:</title>
  #       <cmavo-entry>
  #         <cmavo>nu</cmavo>
  #         <description>event of</description>
  #       </cmavo-entry>
  #
  #       More:
  #
  #      <cmavo-entry>
  #        <cmavo>pu'u</cmavo>
  #        <description>process of</description>
  #        <gismu>pruce</gismu>
  #        <rafsi>pup</rafsi>
  #        <description role="place-structure">x1 is a process of (the bridi)</description>
  #      </cmavo-entry>
  #       <cmavo-entry>
  #         <gismu>fasnu</gismu>
  #         <rafsi>nun</rafsi>
  #         <description role="place-structure">x1 is an event of (the bridi)</description>
  # 
  # other options:
  # 
  #         <modal-place>as said by</modal-place>
  #         <modal-place se="se">expressing</modal-place>
  # 
  #         <series>mi-series</series>
  # 
  #         <pseudo-cmavo>[N]roi</pseudo-cmavo>
  # 
  #         <attitudinal-scale point="sai">discovery</attitudinal-scale>
  # 
  #       </cmavo-entry>
  handle_children( node: node, allowed_children_names: [ 'cmavo-list-head', 'title', 'cmavo-entry' ] ) do |child|
    if child.name == 'cmavo-list-head'
      origname=child.name
      new = convert!( node: child, newname: 'tr' )
      new.replace( %Q{<thead role="#{origname}">#{new}</thead>} )
    elsif child.name == 'title'
      # do nothing
    elsif child.name == 'cmavo-entry'
      #         <cmavo>ju'i</cmavo>
      #         <gismu>[jundi]</gismu>
      #         <attitudinal-scale point="sai">attention</attitudinal-scale>
      #         <attitudinal-scale point="cu'i">at ease</attitudinal-scale>
      #         <attitudinal-scale point="nai">ignore me/us</attitudinal-scale>
      #         <description role="long">
      # 
      #           <quote>Attention/Lo/Hark/Behold/Hey!/Listen, X</quote>; indicates an important communication that the listener should listen to.
      #         </description>

      if child.xpath('./cmavo').length > 0 and child.xpath('./description').length > 0

        # Deal with various grandchildren, removing them so we can
        # be sure we got everything

        newchildren = []
        oldchild = child.clone

        child.xpath('.//comment()').remove

        handle_children( node: child, allowed_children_names: [ 'gismu', 'cmavo', 'selmaho', 'series', 'rafsi', 'compound' ], ignore_others: true ) do |gc|
          new = gc.clone
          convert!( node: new, newname: 'td' )
          newchildren << new
          gc.remove
        end

        [ 'sai', 'nai', "cu'i" ].each do |point|
          scale_bits = child.xpath("./attitudinal-scale[@point=\"#{point}\"]")
          if scale_bits.length > 0
            new = scale_bits.first.clone
            convert!( node: new, newname: 'td' )
            new.content = scale_bits.map { |x| x.text }.join(' ; ')
            new['class'] = "attitudinal-scale-#{point}".gsub("'",'h')
            new.attributes['point'].remove
            newchildren << new
            scale_bits.remove
          end
        end

        descs=child.xpath('./description')

        # Check if we missed something (we have if there's
        # anything left except descriptions)
        if descs.length != child.children.length
          abort "Unhandled node in cmavo-list.  #{descs.length} != #{child.children.length} I'm afraid you'll have to look at the code to see which one.  Here's the whole thing: #{oldchild.to_xml}\n\nhere's what we have left: #{child.to_xml}\n\nand here's what we have so far: #{Nokogiri::XML::NodeSet.new( $document, newchildren ).to_xml}"
        end

        # Make new rows for the longer description elements
        short_descs=[]
        long_descs=[]
        descs.each do |desc|
          $stderr.puts "desc info: #{desc['role']} -- #{desc}"
          if desc['role'] and (desc['role'] == 'place-structure' or desc['role'] == 'long')
            long_descs << desc
          else
            short_descs << desc
          end
        end

        short_descs.each do |desc|
          new = desc.clone
          convert!( node: new, newname: 'td', role: desc['role'] )
          # No "role" for td
          if new['role']
            new['class'] = new['role']
            new.attributes['role'].remove
          end
          newchildren << new
        end

        trs = []

        newchildrengroup = Nokogiri::XML::NodeSet.new( $document, newchildren )
        tr1 = $document.parse("<tr class='cmavo-entry-main'>#{newchildrengroup}</tr>").first

        trs << tr1

        long_descs.each do |desc|
          convert!( node: desc, newname: 'para', role: desc['role'] )
          trs << $document.parse("<tr class='cmavo-entry-long-desc'><td colspan='0'>#{desc}</td></tr>").first
        end

        group = Nokogiri::XML::NodeSet.new( $document, trs )
        child = child.replace group
      else
        handle_children( node: child, allowed_children_names: [ 'gismu', 'cmavo', 'selmaho', 'series', 'rafsi', 'compound', 'modal-place', 'attitudinal-scale', 'pseudo-cmavo', 'description' ] ) do |grandchild|
          role=grandchild.name
          if grandchild[:role]
            role=grandchild[:role]
          elsif grandchild.name == 'series'
            role='cmavo-series'
          elsif grandchild.name == 'compound'
            role='cmavo-compound'
          elsif grandchild.name == 'modal-place'
            role="modal-place-#{grandchild[:se]}"
          elsif grandchild.name == 'attitudinal-scale'
            role="attitudinal-scale-#{grandchild[:point]}".gsub("'",'h')
          end

          convert!( node: grandchild, newname: 'para', role: role )
        end

        child.children.each { |e| e.replace("<td class='#{e['role']}'>#{e}</td>") }
        convert!( node: child, newname: 'tr' )
      end
    else
      abort "Bad node in cmavo-list: #{child.to_xml}"
    end

  end

  tableify node
end

$document.css('letteral,diphthong,cmevla,morphology,rafsi').each do |node|
  convert!( node: node, newname: 'foreignphrase', lang: 'jbo' )
end

$document.css('comment').each do |node|
  convert!( node: node, newname: 'emphasis' )
end

$document.css('comment').each do |node|
  convert!( node: node, newname: 'emphasis' )
end

# Drop attributes that docbook doesn't recognize
$document.xpath('//@glossary').remove
$document.xpath('//@delineated').remove
$document.xpath('//@elidable').remove
$document.xpath('//@valid').remove
$document.xpath('//@split').remove
$document.xpath('//@se').remove
$document.xpath('//@point').remove

doc = $document.to_xml
# Put in our own header
doc = doc.gsub( %r{^.*<book [^>]*>}m, '<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE book PUBLIC "-//OASIS//DTD DocBook XML V5.0//EN" "dtd/docbook-5.0.dtd"[
<!ENTITY % allent SYSTEM "xml/iso-pub.ent">
%allent;
]>
<book xmlns:xlink="http://www.w3.org/1999/xlink">
' )

puts doc

exit 0

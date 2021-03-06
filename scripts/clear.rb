# install pdftohtml in your system (https://poppler.freedesktop.org/)
# gem install posix-spawn nokogiri axlsx
require 'posix/spawn'
require 'nokogiri'
require 'axlsx'

class String
  def clean
    self.gsub(/\s+/, ' ').strip
  end
end

PDF_PATH = ARGV[0]
DEBUG = true

# PN => 4
# ON => 3
# UNT => 11

MAPA_PAPEIS = {
  'ALUPAR'          => 'ALUP11',
  'BTGP BANCO'      => 'BPAC11',
  'COSAN LOG'       => 'RLOG3',
  'CVC BRASIL'      => 'CVCB3',
  'EQUATORIAL'      => 'EQTL3',
  'EZTEC'           => 'EZTC3',
  'GERDAU MET'      => 'GOAU4',
  'HELBOR'          => 'HBOR3',
  'JEREISSATI'      => 'JPSA3',
  'KROTON'          => 'KROT3',
  'LOJAS RENNER'    => 'LREN3',
  'MOVIDA'          => 'MOVI3',
  'OI'              => 'OIBR3',
  'PETROBRAS'       => 'PETR4',
  'PETRORIO'        => 'PRIO3',
  'RANDON PART'     => 'RAPT4',
  'RUMO S.A.'       => 'RAIL3',
  'SINQIA'          => 'SQIA3',
  'SLC AGRICOLA'    => 'SLCE3',
  'SMILES'          => 'SMLS3',
  'TELEF BRASIL'    => 'VIVT4',
  'VIAVAREJO'       => 'VVAR3',
}

cmd = "pdftohtml -stdout -xml -i -fontfullname \"#{PDF_PATH}\" 2>&1"
puts "Running command: #{cmd}"
xml = POSIX::Spawn::Child.new(cmd).out
File.open('tmp/pdf.xml', 'wb') { |f| f.write xml } if DEBUG

doc = Nokogiri::XML(xml)
data_operacao   = doc.xpath('//text[text()="Data pregão"]').first&.next_element&.text.to_s.clean
data_liquidacao = doc.xpath('//b[contains(text(),"Líquido para")]').map { |node| node.text.to_s.split(/\s/).last.clean }.find { |node| node.match(/[0-9]/) }

package = Axlsx::Package.new
workbook = package.workbook
sheet = workbook.add_worksheet(:name => "Operações")

sheet.add_row([
  'DATA OPERACAO',
  'DATA LIQUIDACAO',
  'ATIVO',
  'OPERACAO',
  'DAYTRADE?',
  'PAPEL',
  'QTD',
  'PRECO',
])

operacoes = {}
pages = doc.xpath('//page').to_a
liquidacoes = pages.map { |page| page.xpath('.//b[contains(text(),"Líquido para")]').first&.text.to_s.split(/\s/).last.to_s.clean }
pages.each_with_index do |page, i|
  _data_operacao   = page.xpath('.//text[text()="Data pregão"]').first&.next_element&.text.to_s.clean
  # _data_liquidacao = page.xpath('.//b[contains(text(),"Líquido para")]').first&.text.to_s.split(/\s/).last.to_s.clean
  _data_liquidacao = liquidacoes[i..-1].find { |l| l.match(/[0-9]/) }.to_s
  data_operacao   = _data_operacao if _data_operacao.match(/[0-9]/)
  data_liquidacao = _data_liquidacao if _data_liquidacao.match(/[0-9]/)
  tops = {}
  page.xpath('.//text[@top]').each do |text|
    top = text.attr('top')
    next if tops[top]
    tops[top] = top
    values = page.xpath(".//text[@top='#{top}']").map do |cell|
      [cell.attr('left'), cell.text.clean]
    end.sort_by { |left, value| left.to_i }.map(&:last)
    row = values.join(' ')
    if row.match(/1\-BOVESPA/i)
      ativo = case row.to_s
              when / OPCAO /i
                'OPCAO'
              when / VISTA | FRACION.+RIO /i
                row.match(/ FII /i) ? 'FII' : 'ACAO'
              else
                ''
              end
      empresa = row[/(VISTA|FRACIONARIO|[0-9]{2}\/[0-9]{2})\s+(.+)\s+(ON|PN|CI|UNT)/i, 2]
      empresa = empresa.split(/\s/).last.to_s if empresa.to_s.match(/\AFII/i)
      papel   = MAPA_PAPEIS[empresa] || empresa
      numeros = row[/\s+[0-9,.]+\s+[0-9,.]+\s+[0-9,.]+/, 0].split(/\s+/).map { |num| num.gsub('.', '') }.find_all { |s| s.size > 0 }
      operacao = {}
      operacao['DATA OPERACAO']   = data_operacao
      operacao['DATA LIQUIDACAO'] = data_liquidacao
      operacao['ATIVO']           = ativo
      operacao['OPERACAO']        = row[/BOVESPA C /i] ? 'COMPRA' : 'VENDA'
      operacao['DAYTRADE?']       = 'N'
      operacao['QTD']             = numeros[0].to_i
      operacao['PRECO']           = numeros[1]
      operacoes[papel] ||= []
      operacoes[papel] << operacao
    end
  end
end

# reduce operations by grouping with the same price
operacoes.each do |papel, ops|
  ops.each do |operacao|
    next if operacao['_SHOULD_REMOVE']
    ops.each do |op|
      next if operacao.equal?(op)
      if operacao['DATA LIQUIDACAO'] == op['DATA LIQUIDACAO'] &&
         operacao['OPERACAO'] == op['OPERACAO'] &&
         operacao['PRECO'] == op['PRECO']
         operacao['QTD'] += op['QTD']
         op['_SHOULD_REMOVE'] = true
      end
    end
  end
  ops.delete_if { |operacao| operacao['_SHOULD_REMOVE'] }
end

# find daytrades
operacoes.keys.each do |papel|
  ops = operacoes[papel]
  compras = ops.find_all { |op| op['OPERACAO'] == 'COMPRA' }
  vendas  = ops.find_all { |op| op['OPERACAO'] == 'VENDA' }
  compra = compras.sum { |op| op['QTD'] }
  venda  = vendas.sum { |op| op['QTD'] }
  if compra > 0 && venda > 0
    preco_compra = compras.sum { |op| op['QTD'] * op['PRECO'].gsub(',', '.').to_f } / compra
    preco_venda  = vendas.sum { |op| op['QTD'] * op['PRECO'].gsub(',', '.').to_f } / venda
    operacao_proto = compras.first
    ops = []
    if compra > venda
      ops << operacao_proto.merge('OPERACAO' => 'COMPRA', 'QTD' => compra - venda, 'PRECO' => ('%.2f' % preco_compra).gsub('.', ','), 'DAYTRADE?' => 'N')
      ops << operacao_proto.merge('OPERACAO' => 'COMPRA', 'QTD' => venda, 'PRECO' => ('%.2f' % preco_compra).gsub('.', ','), 'DAYTRADE?' => 'S')
      ops << operacao_proto.merge('OPERACAO' => 'VENDA', 'QTD' => venda, 'PRECO' => ('%.2f' % preco_venda).gsub('.', ','), 'DAYTRADE?' => 'S')
    else
      ops << operacao_proto.merge('OPERACAO' => 'VENDA', 'QTD' => venda - compra, 'PRECO' => ('%.2f' % preco_venda).gsub('.', ','), 'DAYTRADE?' => 'N')
      ops << operacao_proto.merge('OPERACAO' => 'VENDA', 'QTD' => compra, 'PRECO' => ('%.2f' % preco_venda).gsub('.', ','), 'DAYTRADE?' => 'S')
      ops << operacao_proto.merge('OPERACAO' => 'COMPRA', 'QTD' => compra, 'PRECO' => ('%.2f' % preco_compra).gsub('.', ','), 'DAYTRADE?' => 'S')
    end
    operacoes[papel] = ops
  end
end

operacoes.each do |papel, ops|
  ops.each do |op|
    sheet.add_row([
      op['DATA OPERACAO'],
      op['DATA LIQUIDACAO'],
      op['ATIVO'],
      op['OPERACAO'],
      op['DAYTRADE?'],
      papel,
      op['QTD'],
      op['PRECO'],
    ])
  end
end

package.serialize(PDF_PATH.gsub(/\.pdf\Z/i, '.xlsx'))

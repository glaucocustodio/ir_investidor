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

def parse_nota_corretagem(nota_corretagem)
  cmd = "pdftohtml -stdout -xml -i -fontfullname \"#{nota_corretagem}\" 2>&1"
  puts "Running command: #{cmd}"
  xml = POSIX::Spawn::Child.new(cmd).out

  File.open('tmp/pdf.xml', 'wb') { |f| f.write xml } if DEBUG

  doc = Nokogiri::XML(xml)
  data_operacao   = doc.xpath('//text[text()="Data pregão"]').first&.next_element&.text.to_s.clean
  data_liquidacao = doc.xpath('//b[contains(text(),"Líquido para")]').map { |node| node.text.to_s.split(/\s/).last.clean }.find { |node| node.match(/[0-9]/) }

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
                  row.match(/ FII /i) ? 'fii' : 'ação'
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

  operacoes
end

NOTAS_PATH = ARGV[0]
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
  'IOCHP-MAXION'    => 'MYPK3',
  'TAESA'           => 'TAEE11',
  'WEG'             => 'WEGE3',
  'FLEURY'          => 'FLRY3',
  'ITAUSA'          => 'ITSA4',
  'TRISUL'          => 'TRIS3',
  'LOCAMERICA'      => 'LCAM3',
  'B3'              => 'B3SA3',
  'ENERGIAS BR'     => 'ENBR3',
  'SUZANO S.A.'     => 'SUZB3',
  'KLABIN S/A'      => 'KLBN11',
  'WIZ S.A.'        => 'WIZS3',
  'UNIPAR'          => 'UNIP6',
  'MAGAZ LUIZA'     => 'MGLU3',
  'IRBBRASIL RE'    => 'IRBR3',
  'METAL LEVE'      => 'LEVE3',
  'BRADESCO'        => 'BBDC4',
  'ENGIE BRASIL'    => 'EGIE3',
  'TIM PART S/A'    => 'TIMP3',
  'BBSEGURIDADE'    => 'BBSE3',
  'JSL'             => 'JSLG3',
  'PETROBRAS BR'    => 'BRDT3',
  'ABC BRASIL'      => 'ABCB4',
  'SANEPAR'         => 'SAPR4',
  'JHSF PART'       => 'JHSF3'
}

package = Axlsx::Package.new
workbook = package.workbook
sheet = workbook.add_worksheet(:name => "Operações")
sheet.add_row([
  'DATA OPERACAO',
  'PAPEL',
  # 'DATA LIQUIDACAO',
  'TIPO',
  'OPERACAO',
  # 'DAYTRADE?',
  'QTD',
  'PRECO',
])

notas_corretagem = Dir.glob("#{NOTAS_PATH}/*.pdf").sort
notas_corretagem.each do |nota|
  operacoes = parse_nota_corretagem(nota)

  operacoes.each do |papel, ops|
    ops.each do |op|
      sheet.add_row([
        Date.parse(op['DATA OPERACAO']).strftime('%d/%m/%y'),
        # op['DATA LIQUIDACAO'],
        papel,
        op['ATIVO'],
        op['OPERACAO'].downcase,
        # op['DAYTRADE?'],
        op['QTD'],
        op['PRECO'].sub(',', '.'),
      ])
    end
  end
end

package.serialize('resultado.xlsx')

import SubtitolCore

func testGalicianNumbers() {
    let numbers = GalicianNumbers()
    let cases: [(String, String)] = [
        // Ten and below stay in letters (UNE 153010); from 11 on, digits.
        ("tiña dez anos", "tiña dez anos"),
        ("tiña once anos", "tiña 11 anos"),
        ("son dous irmáns e dúas irmás", "son dous irmáns e dúas irmás"),
        ("hai sete persoas", "hai sete persoas"),
        ("dezaseis equipos", "16 equipos"),
        ("dezanove", "19"),
        ("vinte", "20"),
        // Tens joined by "e", both genders.
        ("vinte e tres anos", "23 anos"),
        ("vinte e un anos", "21 anos"),
        ("vinte e unha persoas", "21 persoas"),
        ("trinta e dúas casas", "32 casas"),
        ("noventa e nove", "99"),
        ("corenta e cinco minutos", "45 minutos"),
        // Hundreds: cen alone, cento before the rest, gendered hundreds.
        ("cen persoas", "100 persoas"),
        ("cento vinte e tres", "123"),
        ("cento un", "101"),
        ("douscentos euros", "200 euros"),
        ("duascentas cincuenta e dúas vacas", "252 vacas"),
        ("quiñentos anos", "500 anos"),
        ("cincocentas mulleres", "500 mulleres"),
        ("tres centos", "300"),
        ("cento e vinte", "120"),
        // Thousands: compact up to four digits, a space in threes from five.
        ("mil persoas", "1000 persoas"),
        ("dous mil vinte e seis", "2026"),
        ("mil novecentos noventa e dous", "1992"),
        ("dez mil persoas", "10 000 persoas"),
        ("cen mil habitantes", "100 000 habitantes"),
        ("douscentos cincuenta mil", "250 000"),
        ("mil e cen", "1100"),
        ("entre mil e dous mil", "entre 1000 e 2000"),
        ("dous mil e pico", "2000 e pico"),
        // Millions.
        ("un millón douscentos mil", "1 200 000"),
        ("vinte millóns de euros", "20 millóns de euros"),
        ("tres millóns de persoas", "tres millóns de persoas"),
        ("un millón de grazas", "un millón de grazas"),
        ("mil millóns", "1000 millóns"),
        ("tres coma cinco millóns", "3,5 millóns"),
        // Percentages, always digits.
        ("quince por cento", "15 %"),
        ("o cinco por cento", "o 5 %"),
        ("un por cento", "1 %"),
        ("vinte e tres por cen", "23 %"),
        ("dous coma cinco por cento", "2,5 %"),
        ("tres coma cero cinco por cento", "3,05 %"),
        ("o cen por cento", "o cen por cento"),
        ("douscentos por cento", "200 %"),
        // Dates and years.
        ("o vinte e tres de abril", "o 23 de abril"),
        ("o dous de maio de dous mil vinte e seis", "o 2 de maio de 2026"),
        ("o un de xaneiro", "o 1 de xaneiro"),
        ("o primeiro de maio", "o primeiro de maio"),
        ("en mil novecentos setenta e cinco", "en 1975"),
        ("o trinta e un de decembro", "o 31 de decembro"),
        // Decimals.
        ("vinte coma cinco graos", "20,5 graos"),
        // Digits the recogniser already wrote stay as they are.
        ("de 53 anos", "de 53 anos"),
        ("o 15 por cento", "o 15 %"),
        ("en 2026", "en 2026"),
        // Idioms and false friends.
        ("mil grazas", "mil grazas"),
        ("xa cho dixen mil veces", "xa cho dixen mil veces"),
        ("as mil e unha noites", "as mil e unha noites"),
        ("un home e unha muller", "un home e unha muller"),
        ("unha vez", "unha vez"),
        ("un cento de ovos", "un cento de ovos"),
        ("peixes de auga doce", "peixes de auga doce"),
        ("a auga doce dos ríos", "a auga doce dos ríos"),
        ("un doce de leite", "un doce de leite"),
        ("tiña doce anos", "tiña 12 anos"),
        ("ás doce", "ás 12"),
        ("os dos anos vinte", "os dos anos 20"),
        ("entre os vinte e os trinta", "entre os 20 e os 30"),
        ("trinta e tantos", "30 e tantos"),
        ("Vinte E Tres", "23"),
    ]
    for (spoken, written) in cases {
        check(numbers.normalize(spoken), equals: written, "gl numbers: \(spoken)")
    }

    // A mark after a number word ends the number.
    let list = numbers.replacements(in: ["trinta", "dous", "anos"], boundaries: [0])
    check(list.map(\.text), equals: ["30"], "gl: a comma after the tens stops the number")
    let joined = numbers.replacements(in: ["vinte", "e", "tres", "anos"], boundaries: [0])
    check(joined.map(\.text), equals: ["20"], "gl: a comma before the e keeps the unit apart")
    let items = numbers.replacements(in: ["once", "doce", "trece"], boundaries: [0, 1])
    check(items.map(\.text), equals: ["11", "12", "13"], "gl: a counted list converts doce too")
    check(items.map(\.range), equals: [0..<1, 1..<2, 2..<3], "gl: each listed number keeps its word")
    let percent = numbers.replacements(in: ["quince", "por", "cento"], boundaries: [0])
    check(percent.map(\.text), equals: ["15"], "gl: a comma before por cento is no percentage")
    let date = numbers.replacements(in: ["o", "dous", "de", "maio"], boundaries: [1])
    check(date.isEmpty, "gl: a comma after the day is no date")
    let thousands = numbers.replacements(in: ["dous", "mil", "vinte"], boundaries: [1])
    check(thousands.map(\.text), equals: ["2000", "20"], "gl: a comma after mil splits the number")
    let range = numbers.replacements(in: ["o", "vinte", "e", "tres", "por", "cento", "dos", "votos"], boundaries: [])
    check(range.first?.range, equals: 1..<6, "gl: the percentage covers por cento")

    // What a display waits for.
    check(numbers.mayExtendNumber("vinte", after: nil), "gl: vinte may grow")
    check(numbers.mayExtendNumber("dous", after: "o"), "gl: dous may become a date")
    check(numbers.mayExtendNumber("e", after: "vinte"), "gl: e after vinte may join a unit")
    check(numbers.mayExtendNumber("por", after: "quince"), "gl: por after a number may be a percentage")
    check(numbers.mayExtendNumber("por", after: "15"), "gl: por after digits may be a percentage")
    check(numbers.mayExtendNumber("coma", after: "dous"), "gl: coma after a number may open decimals")
    check(numbers.mayExtendNumber("mil", after: "dous"), "gl: mil may grow")
    check(numbers.mayExtendNumber("millóns", after: "tres"), "gl: millóns may grow")
    check(numbers.mayExtendNumber("un", after: "e"), "gl: un after e ends a compound")
    check(!numbers.mayExtendNumber("un", after: "hai"), "gl: the article un does not wait")
    check(!numbers.mayExtendNumber("unha", after: nil), "gl: the article unha does not wait")
    check(!numbers.mayExtendNumber("e", after: "casa"), "gl: e after a word does not wait")
    check(!numbers.mayExtendNumber("por", after: "vai"), "gl: por after a word does not wait")
    check(!numbers.mayExtendNumber("dos", after: "casa"), "gl: the contraction dos is no number")
    check(!numbers.mayExtendNumber("casa", after: "vinte"), "gl: a noun after a number does not wait")
}

import SubtitolCore

/// Spoken Spanish numbers → digits (`SpanishNumbers`), in the style documented there:
/// letters below ten, a no-break space for grouping and before %, days and percent in
/// digits, clock times, decades and idioms in words.
func testSpanishNumbers() {
    let numbers = SpanishNumbers()
    let nb = "\u{00A0}"
    let cases: [(String, String)] = [
        // Around the threshold: zero to nine stay in words, 10 and up become digits.
        ("tengo nueve años", "tengo nueve años"),
        ("tengo diez años", "tengo 10 años"),
        ("son once personas", "son 11 personas"),
        ("cero", "cero"),
        ("dieciséis y diecinueve", "16 y 19"),
        ("veintitrés alumnos", "23 alumnos"),
        // Compounds with "y", and gender.
        ("tiene treinta y dos años", "tiene 32 años"),
        ("treinta y un días", "31 días"),
        ("cuarenta y una mujeres", "41 mujeres"),
        ("veintiún hombres y veintiuna mujeres", "21 hombres y 21 mujeres"),
        ("entre treinta y cuarenta", "entre 30 y 40"),
        // Hundreds.
        ("cien euros", "100 euros"),
        ("ciento tres páginas", "103 páginas"),
        ("doscientas personas", "200 personas"),
        ("quinientos cincuenta y cinco", "555"),
        ("novecientas noventa y nueve", "999"),
        // Thousands, grouped with a space from five digits.
        ("tres mil doscientas personas", "3200 personas"),
        ("mil personas", "1000 personas"),
        ("diez mil euros", "10\(nb)000 euros"),
        ("veintiún mil votos", "21\(nb)000 votos"),
        ("ciento veinte mil quinientos", "120\(nb)500"),
        // Millions: round ones keep the word, below ten in letters.
        ("un millón de euros", "un millón de euros"),
        ("tres millones de personas", "tres millones de personas"),
        ("veinte millones de euros", "20\(nb)millones de euros"),
        ("mil millones", "1000\(nb)millones"),
        ("un millón doscientos mil", "1\(nb)200\(nb)000"),
        ("dos coma cinco millones", "2,5\(nb)millones"),
        // Percent, always in digits.
        ("quince por ciento", "15\(nb)%"),
        ("un cinco por ciento", "un 5\(nb)%"),
        ("el cincuenta por cien", "el 50\(nb)%"),
        ("tres coma dos por ciento", "3,2\(nb)%"),
        ("cero coma cero cinco", "0,05"),
        // Dates and years.
        ("el veintitrés de abril de dos mil veintiséis", "el 23 de abril de 2026"),
        ("el cinco de mayo", "el 5 de mayo"),
        ("el uno de enero", "el 1 de enero"),
        ("el día cinco", "el día 5"),
        ("en mil novecientos noventa y dos", "en 1992"),
        ("el año dos mil", "el año 2000"),
        ("los años noventa", "los años noventa"),
        ("en el siglo veintiuno", "en el siglo XXI"),
        ("del siglo cinco al diez", "del siglo V al X"),
        ("los siglos quince y dieciséis", "los siglos XV y XVI"),
        // Clock times stay in words.
        ("a las ocho y veinte", "a las ocho y veinte"),
        ("a las once de la noche", "a las once de la noche"),
        ("las doce menos cuarto", "las doce menos cuarto"),
        ("las doce personas", "las 12 personas"),
        // Idioms and false friends.
        ("mil gracias", "mil gracias"),
        ("te lo he dicho mil veces", "te lo he dicho mil veces"),
        ("las mil y una noches", "las mil y una noches"),
        ("al cien por cien", "al cien por cien"),
        ("una vez", "una vez"),
        ("uno de ellos", "uno de ellos"),
        ("un hombre y una mujer", "un hombre y una mujer"),
        ("estuvo en coma", "estuvo en coma"),
        ("miles de personas", "miles de personas"),
        ("el diez por ciento", "el 10\(nb)%"),
        // Case-insensitive; digits the recogniser already wrote are left alone.
        ("Veinte Personas", "20 Personas"),
        ("el 10 por ciento", "el 10\(nb)%"),
        ("en 2026 y 1992", "en 2026 y 1992"),
    ]
    for (spoken, written) in cases {
        check(numbers.normalize(spoken), equals: written, "Spanish numbers: \(spoken)")
    }

    // A punctuation mark between two number words keeps them apart.
    let list = numbers.replacements(in: ["treinta", "dos", "cuarenta"], boundaries: [0])
    check(list.map(\.text), equals: ["30", "40"], "Spanish: a comma after the tens stops the number")
    let joined = numbers.replacements(in: ["treinta", "y", "dos"], boundaries: [0])
    check(joined.map(\.text), equals: ["30"], "Spanish: a comma before 'y' stops 'treinta y dos'")
    let thousands = numbers.replacements(in: ["tres", "mil", "personas"], boundaries: [0])
    check(thousands.map(\.text), equals: ["1000"], "Spanish: 'tres, mil' is not 3000")
    let percent = numbers.replacements(in: ["quince", "por", "ciento"], boundaries: [0])
    check(percent.map(\.text), equals: ["15"], "Spanish: a comma before 'por ciento' keeps it apart")
    let date = numbers.replacements(in: ["el", "veintitrés", "de", "abril"], boundaries: [])
    check(date.first?.range, equals: 1..<2, "Spanish: a day replaces only its own word")
    let whole = numbers.replacements(in: ["quince", "por", "ciento", "más"], boundaries: [])
    check(whole.first?.range, equals: 0..<3, "Spanish: percent covers 'por ciento'")

    // Words a display must hold back until the two after them arrive.
    check(numbers.mayExtendNumber("cinco", after: "el"), "Spanish: 'cinco' may become '5 %'")
    check(numbers.mayExtendNumber("mil", after: nil), "Spanish: 'mil' may be 'mil gracias'")
    check(numbers.mayExtendNumber("y", after: "treinta"), "Spanish: 'y' after a ten may join a unit")
    check(numbers.mayExtendNumber("y", after: "mil"), "Spanish: 'mil y' may be 'mil y una'")
    check(numbers.mayExtendNumber("por", after: "quince"), "Spanish: 'por' after a number may be percent")
    check(numbers.mayExtendNumber("Por", after: "10"), "Spanish: 'por' after digits may be percent")
    check(numbers.mayExtendNumber("coma", after: "dos"), "Spanish: 'coma' after a number may be a decimal")
    check(numbers.mayExtendNumber("10", after: "el"), "Spanish: digits may take 'por ciento'")
    check(!numbers.mayExtendNumber("un", after: "es"), "Spanish: the article 'un' does not wait")
    check(!numbers.mayExtendNumber("una", after: nil), "Spanish: 'una' does not wait")
    check(!numbers.mayExtendNumber("y", after: "casa"), "Spanish: an ordinary 'y' does not wait")
    check(!numbers.mayExtendNumber("y", after: "cinco"), "Spanish: 'cinco y' cannot grow")
    check(!numbers.mayExtendNumber("por", after: "voy"), "Spanish: an ordinary 'por' does not wait")
    check(!numbers.mayExtendNumber("coma", after: "en"), "Spanish: 'en coma' does not wait")
    check(!numbers.mayExtendNumber("casa", after: "cinco"), "Spanish: ordinary words do not wait")
}

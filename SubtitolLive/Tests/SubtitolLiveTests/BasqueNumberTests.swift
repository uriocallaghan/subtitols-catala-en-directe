import SubtitolCore

/// Euskaltzaindia's rule 203: one-word numbers in letters, longer ones above twenty in
/// digits, the case suffix straight after the digits, "% 15", dates and years in digits.
func testBasqueNumbers() {
    let numbers = BasqueNumbers()
    let space = "\u{00A0}"
    let cases: [(String, String)] = [
        // One-word numbers stay in letters; above twenty, two words or more are digits.
        ("bost urte", "bost urte"),
        ("hemeretzi lagun", "hemeretzi lagun"),
        ("hogei lagun", "hogei lagun"),
        ("hogeita bat urte", "21 urte"),
        ("hogeita hamar talde", "30 talde"),
        ("berrogeita hamar kilometroko azalera", "50 kilometroko azalera"),
        ("hirurogeita hamabi eman dugu", "72 eman dugu"),
        ("laurogeita hemeretzi", "99"),
        ("ehun urte", "ehun urte"),
        ("ehun eta hogei", "120"),
        ("berrehun eta berrogeita hamar euro", "250 euro"),
        ("zazpi mila hirurehun eta berrogeita bost euro", "7345 euro"),
        ("hamar mila lagun", "10\(space)000 lagun"),
        ("berrehun mila pertsona", "200\(space)000 pertsona"),
        ("hamabost milioi euro", "15\(space)milioi euro"),
        ("bi milioi euro", "bi milioi euro"),
        ("hiru milioi berrehun mila", "3\(space)200\(space)000"),
        ("bi milioi hamar mila", "2\(space)010\(space)000"),
        ("bi milioi bat lagun", "bi milioi bat lagun"),
        // Years, with and without "eta" after the thousands.
        ("mila bederatziehun eta laurogeita hamabi", "1992"),
        ("mila eta bederatziehun eta laurogeita hamabi", "1992"),
        ("bi mila eta hogeita sei", "2026"),
        ("bi mila eta hogeita seian", "2026an"),
        ("bi mila eta hamaseiko akordio", "2016ko akordio"),
        ("bi mila eta hamaikan", "2011n"),
        ("bi milan", "2000n"),
        ("bi mila hogeita sei", "2026"),
        ("mila bederatziehun eta berrogeita bosgarren urtean", "1945. urtean"),
        // Case suffixes attach to the digits, as spoken after the number's stem.
        ("hogeita hamarrean", "30ean"),
        ("hogeita batetik", "21etik"),
        ("berrogeita hamaikak", "51k"),
        ("ehun eta hogeita bostentzat", "125entzat"),
        ("hogeita hiruretan", "23etan"),
        // Days of the month are digits whatever their size.
        ("apirilaren hogeita hiruan", "apirilaren 23an"),
        ("maiatzaren bostean", "maiatzaren 5ean"),
        ("martxoaren batean", "martxoaren 1ean"),
        ("urriaren hamaikan", "urriaren 11n"),
        ("martxoaren zortzia", "martxoaren 8a"),
        ("abenduaren hogeita hamaikan", "abenduaren 31n"),
        ("bi mila eta hogeita seiko martxoaren hiruan", "2026ko martxoaren 3an"),
        ("martxoaren berrogei", "martxoaren berrogei"),
        // Percent: the sign first, always digits.
        ("ehuneko hamabost", "%\(space)15"),
        ("ehuneko zazpik esan zuten", "%\(space)7k esan zuten"),
        ("ehuneko hogeita bostean", "%\(space)25ean"),
        ("ehuneko hiru koma bi", "%\(space)3,2"),
        ("ehuneko 15", "%\(space)15"),
        ("ehuneko handia", "ehuneko handia"),
        // Decimals, decades, ordinals and centuries.
        ("bi koma zortzi milioi euro", "2,8\(space)milioi euro"),
        ("hirurogeiko hamarkadan", "60ko hamarkadan"),
        ("hirurogeita hamarreko hamarkadan", "70eko hamarkadan"),
        ("hogeita bosgarren urteurrena", "25. urteurrena"),
        ("bederatzigarren geltokian", "bederatzigarren geltokian"),
        ("hogeita batgarren mendean", "XXI. mendean"),
        ("hemeretzigarren mendean", "XIX. mendean"),
        // Words that must stay words.
        ("gizon bat etorri da", "gizon bat etorri da"),
        ("mila bat lagun", "mila bat lagun"),
        ("hogeita hamar bat lagun", "30 bat lagun"),
        ("hogeita hamarren bat eleberri", "hogeita hamarren bat eleberri"),
        ("mila esker", "mila esker"),
        ("hamaika aldiz", "hamaika aldiz"),
        ("milaka pertsona", "milaka pertsona"),
        ("ehunka urte", "ehunka urte"),
        ("aho batez onartu da", "aho batez onartu da"),
        ("zazpiak eta hogeita bost", "zazpiak eta hogeita bost"),
        ("lau bat bat bi", "lau bat bat bi"),
        // Joined spellings, digits already written, capitals.
        ("laumila pertsonentzako", "4000 pertsonentzako"),
        ("hogeitabat urte", "21 urte"),
        ("2026an hasiko da", "2026an hasiko da"),
        ("Hogeita Bost urte", "25 urte"),
    ]
    for (spoken, written) in cases {
        check(numbers.normalize(spoken), equals: written, "basque numbers: \(spoken)")
    }

    // A mark ends a number: "hogeita," is not twenty-something.
    check(numbers.replacements(in: ["hogeita", "bost", "urte"], boundaries: [0]).map(\.text), equals: [],
          "basque: a comma after hogeita stops the number")
    check(numbers.replacements(in: ["hogeita", "bost", "hogeita", "sei"], boundaries: [1]).map(\.text), equals: ["25", "26"],
          "basque: a comma splits a list of numbers")
    check(numbers.replacements(in: ["bi", "mila", "eta", "hogeita", "sei"], boundaries: [1]).map(\.text), equals: ["2000", "26"],
          "basque: a comma after mila keeps eta out")
    check(numbers.replacements(in: ["ehuneko", "hamabost"], boundaries: [0]).map(\.text), equals: [],
          "basque: a comma after ehuneko is no percent")
    check(numbers.replacements(in: ["urte", "hogeita", "bost"], boundaries: []).first?.range, equals: 1..<3,
          "basque: the replacement covers the number's words")
    check(numbers.replacements(in: ["ehuneko", "hamabost", "da"], boundaries: []).first?.range, equals: 0..<2,
          "basque: the percent covers ehuneko")

    // What may still grow into a number.
    check(numbers.mayExtendNumber("bi", after: "urte"), "basque: bi may become bi mila")
    check(numbers.mayExtendNumber("hogeita", after: nil), "basque: hogeita waits for its unit")
    check(!numbers.mayExtendNumber("bat", after: "gizon"), "basque: the article bat does not wait")
    check(numbers.mayExtendNumber("bat", after: "hogeita"), "basque: hogeita bat may become hogeita bat mila")
    check(numbers.mayExtendNumber("eta", after: "mila"), "basque: mila eta waits")
    check(!numbers.mayExtendNumber("eta", after: "bost"), "basque: bost eta does not wait")
    check(numbers.mayExtendNumber("ehuneko", after: nil), "basque: ehuneko waits for its number")
    check(numbers.mayExtendNumber("koma", after: "hiru"), "basque: hiru koma waits for the decimals")
    check(!numbers.mayExtendNumber("koma", after: "gizon"), "basque: koma after a noun does not wait")
    check(!numbers.mayExtendNumber("seian", after: "hogeita"), "basque: a case suffix ends the number")
    check(numbers.mayExtendNumber("hirurogeiko", after: nil), "basque: hirurogeiko may be a decade")
    check(numbers.mayExtendNumber("hogeigarren", after: nil), "basque: an ordinal may be a century")
    check(!numbers.mayExtendNumber("bosgarrena", after: nil), "basque: a declined ordinal ends the number")
    check(!numbers.mayExtendNumber("etxea", after: nil), "basque: an ordinary word does not wait")
    check(numbers.mayExtendNumber("Mila", after: nil), "basque: case does not matter")
}

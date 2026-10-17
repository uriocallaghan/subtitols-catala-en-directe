import SubtitolCore

func testEnglishNumbers() {
    let numbers = EnglishNumbers()
    let cases: [(String, String)] = [
        // Around the threshold: one to ten in words, 11 on in numerals.
        ("i have ten apples", "i have ten apples"),
        ("i have eleven apples", "i have 11 apples"),
        ("she is nineteen", "she is 19"),
        ("twenty people came", "20 people came"),
        ("twenty three people", "23 people"),
        ("twenty-three people", "23 people"),
        ("ninety nine problems", "99 problems"),
        // Hundreds, thousands, millions.
        ("a hundred people", "100 people"),
        ("a hundred and five people", "105 people"),
        ("hundred and five people", "105 people"),
        ("one hundred and twenty one", "121"),
        ("three thousand two hundred people", "3,200 people"),
        ("a thousand people", "1,000 people"),
        ("two thousand and six people", "2,006 people"),
        ("a hundred and fifty thousand people", "150,000 people"),
        ("twelve hundred people", "1,200 people"),
        ("ten thousand years", "10,000 years"),
        ("one million dollars", "1 million dollars"),
        ("three hundred million people", "300 million people"),
        ("one million two hundred thousand", "1,200,000"),
        ("one point five million", "1.5 million"),
        ("between five hundred and six hundred", "between 500 and 600"),
        // Percent.
        ("about fifteen per cent", "about 15%"),
        ("about fifteen percent", "about 15%"),
        ("five percent", "5%"),
        ("two point five per cent", "2.5%"),
        ("a hundred percent sure", "100% sure"),
        // Units take numerals under 11 too; time with o'clock.
        ("five kilometres away", "5 kilometres away"),
        ("at four o'clock", "at 4 o'clock"),
        // Dates, both orders, ordinal suffixes.
        ("on the twenty third of april", "on the 23rd of april"),
        ("april twenty third", "april 23rd"),
        ("the first of may", "the 1st of may"),
        ("on may second", "on may 2nd"),
        ("april three", "april 3"),
        ("the eleventh of november", "the 11th of november"),
        ("the twelfth of june", "the 12th of june"),
        ("twenty second april", "22nd april"),
        // Years.
        ("in nineteen ninety two", "in 1992"),
        ("since twenty twenty", "since 2020"),
        ("in two thousand and six we moved", "in 2006 we moved"),
        ("in two thousand cases", "in 2,000 cases"),
        ("the year two thousand", "the year 2000"),
        ("in nineteen oh five", "in 1905"),
        ("since nineteen hundred", "since 1900"),
        ("fifty five bc", "55 bc"),
        ("in twenty ten", "in 2010"),
        ("in twenty twenty-six", "in 2026"),
        ("april twenty-third", "april 23rd"),
        ("april twenty twenty six", "april 2026"),
        ("the nineteen nineties", "the 1990s"),
        ("in the summer of nineteen sixty nine", "in the summer of 1969"),
        ("from nineteen ninety to nineteen ninety five", "from 1990 to 1995"),
        ("nineteen ninety two was great", "nineteen ninety two was great"),
        ("in twenty minutes", "in 20 minutes"),
        // Ordinals outside dates.
        ("the twenty first century", "the 21st century"),
        ("the first time", "the first time"),
        ("her fiftieth birthday", "her 50th birthday"),
        ("the hundredth time", "the 100th time"),
        // Idioms and false friends that stay words.
        ("one of them", "one of them"),
        ("one day", "one day"),
        ("a thousand thanks", "a thousand thanks"),
        ("i told you a thousand times", "i told you a thousand times"),
        ("hundreds of people", "hundreds of people"),
        ("thousands of people", "thousands of people"),
        ("a million reasons", "a million reasons"),
        ("at the eleventh hour", "at the eleventh hour"),
        ("the fourth of july", "the fourth of july"),
        ("you may first need to", "you may first need to"),
        ("one second", "one second"),
        ("at one point i left", "at one point i left"),
        ("open twenty four seven", "open 24/7"),
        // Already digits: left alone, but "10 per cent" joins.
        ("10 people", "10 people"),
        ("2026", "2026"),
        ("10 per cent", "10%"),
        // Case-insensitive.
        ("On The Twenty Third Of April", "On The 23rd Of April"),
        // The recogniser's own sentence.
        ("about fifteen per cent of the three thousand two hundred people",
         "about 15% of the 3,200 people"),
    ]
    for (spoken, written) in cases {
        check(numbers.normalize(spoken), equals: written, "English numbers: \(spoken)")
    }

    // A mark between number words keeps them apart: "twenty, three".
    let list = numbers.replacements(in: ["twenty", "three", "people"], boundaries: [0])
    check(list.map(\.text), equals: ["20"], "English: a comma after the tens stops the number")
    let halves = numbers.replacements(in: ["in", "twenty", "twenty", "six"], boundaries: [1])
    check(halves.map(\.text), equals: ["20", "26"], "English: a comma splits a year read in halves")
    let percent = numbers.replacements(in: ["fifteen", "per", "cent"], boundaries: [0])
    check(percent.map(\.text), equals: ["15"], "English: a comma before 'per cent' keeps it out")

    // A date's year after the comma: "the 23rd of April, 2026".
    let spoken = ["on", "the", "twenty", "third", "of", "april", "twenty", "twenty", "six"]
    let dated = numbers.replacements(in: spoken, boundaries: [5])
    check(dated.map(\.text), equals: ["23rd", "2026"], "English: day and year of a date")
    check(dated.map(\.range), equals: [2..<4, 6..<9], "English: the date's words are replaced")
    let monthFirst = numbers.replacements(in: ["april", "twenty", "third", "twenty", "twenty", "six"], boundaries: [2])
    check(monthFirst.map(\.text), equals: ["23rd", "2026"], "English: April 23rd, 2026")

    // Words that must wait for what follows.
    check(numbers.mayExtendNumber("fifteen", after: "about"), "English: a number word waits")
    check(numbers.mayExtendNumber("Twenty", after: nil), "English: case-insensitive")
    check(numbers.mayExtendNumber("third", after: "the"), "English: an ordinal may become a date")
    check(numbers.mayExtendNumber("a", after: "about"), "English: 'a' may become 'a hundred'")
    check(numbers.mayExtendNumber("and", after: "hundred"), "English: 'and' after a number")
    check(numbers.mayExtendNumber("per", after: "fifteen"), "English: 'per' after a number")
    check(numbers.mayExtendNumber("point", after: "two"), "English: 'point' after a number")
    check(numbers.mayExtendNumber("10", after: nil), "English: digits may take 'per cent'")
    check(!numbers.mayExtendNumber("and", after: "cats"), "English: 'and' elsewhere settles")
    check(!numbers.mayExtendNumber("per", after: "miles"), "English: 'per' elsewhere settles")
    check(!numbers.mayExtendNumber("the", after: nil), "English: ordinary words settle")
    check(!numbers.mayExtendNumber("people", after: "twenty"), "English: a noun after a number settles")
}

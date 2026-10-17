import Foundation
import SubtitolCore

/// Every word of the first run, in the five languages the app offers for its interface.
///
/// The first run opens in the phone's own language when it is one of these (otherwise in
/// English) and switches the moment the reader picks another on the first screen.
/// `app.interfaceLanguage` stores the choice, and the rest of the app follows it from
/// `Localizable.xcstrings` (see `InterfaceLanguage`). These tables stay here, apart
/// from the catalogue, so the first screen can hold every language at once and swap
/// between them inside one animation. Galician and Basque want a native speaker's
/// review (`.work/five-languages/REVIEW-gl-eu.md`).
struct OnboardingCopy {
    let welcomeTitle: String
    let welcomeBody: String
    let start: String
    let downloadTitle: String
    let downloadBody: String
    /// The same screen when the chosen language is already inside the app: nothing to download.
    let chooseTitle: String
    /// …and the others download once; or every language is inside the app (the Mac).
    let chooseBody: String
    let chooseBodyAll: String
    /// The size tag of a language that is inside the app.
    let included: String
    let download: String
    let `continue`: String
    let micTitle: String
    let micGranted: String
    let micBody: String
    let micDenied: String
    let micAllow: String
    let openSettings: String
    let notNow: String
    let almostReady: String
    let downloadingPercent: (Int) -> String
    let stillDownloading: (Int) -> String
    let downloadFailed: String
    let notDownloaded: String
    /// The way out when a download failed or hangs: retry, or go in and download later.
    let tryAgain: String
    let continueWithout: String
    let preparingLanguage: String
    let pillDownloading: (String, Int) -> String
    let pillReady: (String) -> String
    let back: String
    let step: (Int, Int) -> String
    /// The names of the languages the app reads, in this language.
    let languageNames: [String: String]

    /// The interface languages, in the order they are offered.
    static var languages: [(id: String, name: String)] { InterfaceLanguage.all }

    /// The phone's first language that the interface speaks, else English.
    static var deviceLanguage: String { InterfaceLanguage.deviceLanguage }

    static func `for`(_ id: String) -> OnboardingCopy {
        switch id {
        case "ca": catalan
        case "es": spanish
        case "gl": galician
        case "eu": basque
        default: english
        }
    }

    /// The phone's sentence, or the Mac's where it names the device or its settings.
    private static func device(_ phone: String, mac: String) -> String {
        #if os(iOS)
        phone
        #else
        mac
        #endif
    }

    static let catalan = OnboardingCopy(
        welcomeTitle: "Et donem la benvinguda",
        welcomeBody: device("Subtítols en directe, dins el teu iPhone. Primer de tot: en quina llengua vols l'app?", mac: "Subtítols en directe, dins el teu Mac. Primer de tot: en quina llengua vols l'app?"),
        start: "Som-hi",
        downloadTitle: "Quina llengua vols baixar?",
        downloadBody: "És la llengua que l'app escoltarà i transcriurà. Es baixa un sol cop i després funciona sense connexió.",
        chooseTitle: "Quina llengua vols llegir?",
        chooseBody: "És la llengua que l'app escoltarà i transcriurà. Aquesta ja és dins l'app; les altres es baixen un sol cop.",
        chooseBodyAll: "És la llengua que l'app escoltarà i transcriurà. Totes són dins l'app; la pots canviar quan vulguis.",
        included: "Inclosa",
        download: "Baixa",
        continue: "Continua",
        micTitle: "Deixa'ns escoltar",
        micGranted: "Ja t'escolto",
        micBody: device("La veu es transcriu dins l'iPhone i no s'envia mai enlloc.", mac: "La veu es transcriu dins el Mac i no s'envia mai enlloc."),
        micDenied: device("El micròfon està desactivat. Activa'l a Configuració > duna > Micròfon.", mac: "El micròfon està desactivat. Activa'l a Configuració del Sistema > Privadesa i seguretat > Micròfon."),
        micAllow: "Continua",
        openSettings: device("Obre Configuració", mac: "Obre Configuració del Sistema"),
        notNow: "Ara no",
        almostReady: "Gairebé a punt",
        downloadingPercent: { "Baixant · \($0) %" },
        stillDownloading: { "Encara s'està baixant: \($0) %. De seguida parlem." },
        downloadFailed: "No s'ha pogut baixar. Torna-ho a provar, o continua i baixa-la més tard.",
        notDownloaded: "Torna enrere i baixa una llengua.",
        tryAgain: "Torna-ho a provar",
        continueWithout: "Continua sense idioma",
        preparingLanguage: "Preparant la llengua…",
        pillDownloading: { "Baixant \($0) · \($1) %" },
        pillReady: { "\($0) a punt" },
        back: "Enrere",
        step: { "Pas \($0) de \($1)" },
        languageNames: ["ca": "català", "gl": "gallec", "eu": "basc", "es": "castellà", "en": "anglès"]
    )

    static let spanish = OnboardingCopy(
        welcomeTitle: "Te damos la bienvenida",
        welcomeBody: device("Subtítulos en directo, dentro de tu iPhone. Antes de nada: ¿en qué idioma quieres la app?", mac: "Subtítulos en directo, dentro de tu Mac. Antes de nada: ¿en qué idioma quieres la app?"),
        start: "Vamos allá",
        downloadTitle: "¿Qué idioma quieres descargar?",
        downloadBody: "Es el idioma que la app escuchará y transcribirá. Se descarga una sola vez y después funciona sin conexión.",
        chooseTitle: "¿Qué idioma quieres leer?",
        chooseBody: "Es el idioma que la app escuchará y transcribirá. Este ya viene con la app; los demás se descargan una sola vez.",
        chooseBodyAll: "Es el idioma que la app escuchará y transcribirá. Todos vienen con la app; puedes cambiarlo cuando quieras.",
        included: "Incluido",
        download: "Descargar",
        continue: "Continuar",
        micTitle: "Déjanos escuchar",
        micGranted: "Ya te escucho",
        micBody: device("La voz se transcribe dentro del iPhone y nunca se envía a ningún sitio.", mac: "La voz se transcribe dentro del Mac y nunca se envía a ningún sitio."),
        micDenied: device("El micrófono está desactivado. Actívalo en Ajustes > duna > Micrófono.", mac: "El micrófono está desactivado. Actívalo en Ajustes del Sistema > Privacidad y seguridad > Micrófono."),
        micAllow: "Continuar",
        openSettings: device("Abrir Ajustes", mac: "Abrir Ajustes del Sistema"),
        notNow: "Ahora no",
        almostReady: "Casi listo",
        downloadingPercent: { "Descargando · \($0) %" },
        stillDownloading: { "Todavía se está descargando: \($0) %. Enseguida hablamos." },
        downloadFailed: "No se ha podido descargar. Reinténtalo, o continúa y descárgalo más tarde.",
        notDownloaded: "Vuelve atrás y descarga un idioma.",
        tryAgain: "Reintentar",
        continueWithout: "Continuar sin idioma",
        preparingLanguage: "Preparando el idioma…",
        pillDownloading: { "Descargando \($0) · \($1) %" },
        pillReady: { "\($0) listo" },
        back: "Atrás",
        step: { "Paso \($0) de \($1)" },
        languageNames: ["ca": "catalán", "gl": "gallego", "eu": "euskera", "es": "castellano", "en": "inglés"]
    )

    static let english = OnboardingCopy(
        welcomeTitle: "Welcome",
        welcomeBody: device("Live subtitles, right on your iPhone. First things first: which language would you like the app in?", mac: "Live subtitles, right on your Mac. First things first: which language would you like the app in?"),
        start: "Let's go",
        downloadTitle: "Which language do you want to download?",
        downloadBody: "It's the language the app will listen to and transcribe. It downloads once, then works offline.",
        chooseTitle: "Which language do you want to read?",
        chooseBody: "It's the language the app will listen to and transcribe. This one comes with the app; the others download once.",
        chooseBodyAll: "It's the language the app will listen to and transcribe. All of them come with the app; you can change it whenever you like.",
        included: "Included",
        download: "Download",
        continue: "Continue",
        micTitle: "Let us listen",
        micGranted: "I can hear you",
        micBody: device("Your voice is transcribed on your iPhone and never sent anywhere.", mac: "Your voice is transcribed on your Mac and never sent anywhere."),
        micDenied: device("The microphone is off. Turn it on in Settings > duna > Microphone.", mac: "The microphone is off. Turn it on in System Settings > Privacy & Security > Microphone."),
        micAllow: "Continue",
        openSettings: device("Open Settings", mac: "Open System Settings"),
        notNow: "Not now",
        almostReady: "Almost ready",
        downloadingPercent: { "Downloading · \($0) %" },
        stillDownloading: { "Still downloading: \($0) %. We'll talk in a moment." },
        downloadFailed: "The download didn't finish. Try again, or continue and download it later.",
        notDownloaded: "Go back and download a language.",
        tryAgain: "Try again",
        continueWithout: "Continue without a language",
        preparingLanguage: "Getting the language ready…",
        pillDownloading: { "Downloading \($0) · \($1) %" },
        pillReady: { "\($0) ready" },
        back: "Back",
        step: { "Step \($0) of \($1)" },
        languageNames: ["ca": "Catalan", "gl": "Galician", "eu": "Basque", "es": "Spanish", "en": "English"]
    )

    static let galician = OnboardingCopy(
        welcomeTitle: "Dámosche a benvida",
        welcomeBody: device("Subtítulos en directo, dentro do teu iPhone. Primeiro de todo: en que lingua queres a app?", mac: "Subtítulos en directo, dentro do teu Mac. Primeiro de todo: en que lingua queres a app?"),
        start: "Imos alá",
        downloadTitle: "Que lingua queres descargar?",
        downloadBody: "É a lingua que a app escoitará e transcribirá. Descárgase unha soa vez e despois funciona sen conexión.",
        chooseTitle: "Que lingua queres ler?",
        chooseBody: "É a lingua que a app escoitará e transcribirá. Esta xa vén coa app; as demais descárganse unha soa vez.",
        chooseBodyAll: "É a lingua que a app escoitará e transcribirá. Todas veñen coa app; podes cambiala cando queiras.",
        included: "Incluída",
        download: "Descargar",
        continue: "Continuar",
        micTitle: "Déixanos escoitar",
        micGranted: "Xa te escoito",
        micBody: device("A voz transcríbese dentro do iPhone e nunca se envía a ningures.", mac: "A voz transcríbese dentro do Mac e nunca se envía a ningures."),
        micDenied: device("O micrófono está desactivado. Actívao en Axustes > duna > Micrófono.", mac: "O micrófono está desactivado. Actívao en Axustes do Sistema > Privacidade e seguranza > Micrófono."),
        micAllow: "Continuar",
        openSettings: device("Abrir Axustes", mac: "Abrir Axustes do Sistema"),
        notNow: "Agora non",
        almostReady: "Case listo",
        downloadingPercent: { "Descargando · \($0) %" },
        stillDownloading: { "Aínda se está a descargar: \($0) %. Axiña falamos." },
        downloadFailed: "Non se puido descargar. Téntao de novo, ou continúa e descárgao máis tarde.",
        notDownloaded: "Volve atrás e descarga unha lingua.",
        tryAgain: "Tentar de novo",
        continueWithout: "Continuar sen idioma",
        preparingLanguage: "Preparando a lingua…",
        pillDownloading: { "Descargando \($0) · \($1) %" },
        pillReady: { "\($0) lista" },
        back: "Atrás",
        step: { "Paso \($0) de \($1)" },
        languageNames: ["ca": "catalán", "gl": "galego", "eu": "éuscaro", "es": "castelán", "en": "inglés"]
    )

    static let basque = OnboardingCopy(
        welcomeTitle: "Ongi etorri",
        welcomeBody: device("Azpitituluak zuzenean, zure iPhonean bertan. Lehenik eta behin: zein hizkuntzatan nahi duzu aplikazioa?", mac: "Azpitituluak zuzenean, zure Mac-ean bertan. Lehenik eta behin: zein hizkuntzatan nahi duzu aplikazioa?"),
        start: "Goazen",
        downloadTitle: "Zein hizkuntza deskargatu nahi duzu?",
        downloadBody: "Aplikazioak entzun eta transkribatuko duen hizkuntza da. Behin bakarrik deskargatzen da, eta gero konexiorik gabe dabil.",
        chooseTitle: "Zein hizkuntza irakurri nahi duzu?",
        chooseBody: "Aplikazioak entzun eta transkribatuko duen hizkuntza da. Hau aplikazioarekin batera dator; besteak behin bakarrik deskargatzen dira.",
        chooseBodyAll: "Aplikazioak entzun eta transkribatuko duen hizkuntza da. Guztiak aplikazioarekin batera datoz; nahi duzunean alda dezakezu.",
        included: "Barne",
        download: "Deskargatu",
        continue: "Jarraitu",
        micTitle: "Utzi entzuten",
        micGranted: "Entzuten zaitut",
        micBody: device("Ahotsa iPhonean bertan transkribatzen da, eta ez da inoiz inora bidaltzen.", mac: "Ahotsa Mac-ean bertan transkribatzen da, eta ez da inoiz inora bidaltzen."),
        micDenied: device("Mikrofonoa desaktibatuta dago. Aktibatu Ezarpenak > duna > Mikrofonoa atalean.", mac: "Mikrofonoa desaktibatuta dago. Aktibatu Sistemaren ezarpenak > Pribatutasuna eta segurtasuna > Mikrofonoa atalean."),
        micAllow: "Jarraitu",
        openSettings: device("Ireki Ezarpenak", mac: "Ireki Sistemaren ezarpenak"),
        notNow: "Orain ez",
        almostReady: "Ia prest",
        downloadingPercent: { "Deskargatzen · % \($0)" },
        stillDownloading: { "Oraindik deskargatzen: % \($0). Berehala hitz egingo dugu." },
        downloadFailed: "Ezin izan da deskargatu. Saiatu berriro, edo jarraitu eta deskargatu geroago.",
        notDownloaded: "Itzuli atzera eta deskargatu hizkuntza bat.",
        tryAgain: "Saiatu berriro",
        continueWithout: "Jarraitu hizkuntzarik gabe",
        preparingLanguage: "Hizkuntza prestatzen…",
        pillDownloading: { "\($0) deskargatzen · % \($1)" },
        pillReady: { "\($0) prest" },
        back: "Atzera",
        step: { "\($0). urratsa / \($1)" },
        languageNames: ["ca": "katalana", "gl": "galiziera", "eu": "euskara", "es": "gaztelania", "en": "ingelesa"]
    )
}

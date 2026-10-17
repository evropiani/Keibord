import XCTest
@testable import KeibordCore

/// Evaluation data for `EngineQualityTests`: realistic typo → intended pairs, prefixes, predictions and
/// valid words that must never be autocorrected. Case syntax: "previous words typed>intended".
/// Categories: slip (adjacent key, spatial taps), missing, extra, transposition, double (doubled /
/// undoubled letters), accent (missing diacritics, ß), case (lower-case German nouns, "i"),
/// apostrophe, variety (US spelling in British English), completion.
enum EngineQualityData {
    static let evaluatedLanguages: [KeyboardLanguage] = [.deAT, .enGB, .sqXK, .itIT]

    /// The owner's enabled languages with `first` (the layout language) in front.
    static func ownerLanguages(first: KeyboardLanguage) -> [KeyboardLanguage] {
        [first] + [KeyboardLanguage.deAT, .enGB, .sqXK, .itIT].filter { $0 != first }
    }

    static func typoCases(for language: KeyboardLanguage) -> [EvalCase] {
        (typos[language] ?? []).flatMap { category, specs in specs.map { EvalCase($0, language: language, category: category) } }
    }

    static func completionCases(for language: KeyboardLanguage) -> [EvalCase] {
        (completions[language] ?? []).map { EvalCase($0, language: language, category: "completion") }
    }

    static func curatedValidWords(for language: KeyboardLanguage) -> [String] {
        curated[language] ?? []
    }

    // MARK: Typos

    static let typos: [KeyboardLanguage: [(String, [String])]] = [
        .deAT: [
            ("slip", ["hsus>Haus", "nivht>nicht", "auvh>auch", "jabe>habe", "heite>heute", "nocj>noch", "schpn>schon",
                      "wirklivh>wirklich", "vielleivht>vielleicht", "morgem>morgen", "danle>danke", "bitre>bitte",
                      "gwrne>gerne", "samsrag>Samstag", "arbeizen>arbeiten", "Wochenemde>Wochenende", "frrut>freut",
                      "kpmme>komme", "kimmst>kommst", "Termim>Termin", "sber>aber", "wsrum>warum", "machzn>machen"]),
            ("missing", ["vileicht>vielleicht", "eigntlich>eigentlich", "nämich>nämlich", "Entschldigung>Entschuldigung",
                         "Geburstag>Geburtstag", "wahrscheinich>wahrscheinlich", "Frühtück>Frühstück", "jezt>jetzt",
                         "Wohnng>Wohnung", "gestrn>gestern"]),
            ("extra", ["habben>haben", "unnd>und", "schonn>schon", "jettzt>jetzt", "halllo>hallo", "abber>aber", "wiedder>wieder"]),
            ("transposition", ["ihc>ich", "nicth>nicht", "acuh>auch", "abre>aber", "shcon>schon", "wrid>wird", "Mädhcen>Mädchen",
                               "veilleicht>vielleicht", "dnake>danke"]),
            ("double", ["Kafee>Kaffee", "komen>kommen", "Mitag>Mittag", "zusamen>zusammen", "imer>immer",
                        "Strasse>Straße", "heisst>heißt", "gross>groß", "Fussball>Fußball", "weiss>weiß"]),
            ("accent", ["fur>für", "Madchen>Mädchen", "konnen>können", "mussen>müssen", "naturlich>natürlich", "uber>über",
                        "spater>später", "moglich>möglich", "Fruhstuck>Frühstück", "zuruck>zurück", "Janner>Jänner", "Strase>Straße",
                        "schoen>schön", "Gruße>Grüße"]),
            ("case", ["das haus>Haus", "auto>Auto", "hund>Hund", "tag>Tag", "termin>Termin", "arbeit>Arbeit", "frau>Frau",
                      "wohnung>Wohnung", "geburtstag>Geburtstag", "jause>Jause", "wochenende>Wochenende", "uhr>Uhr",
                      "geld>Geld", "wien>Wien", "mama>Mama", "nachricht>Nachricht"]),
        ],
        .enGB: [
            ("slip", ["thw>the", "anf>and", "yoi>you", "jave>have", "wjat>what", "rhink>think", "becsuse>because",
                      "tomorroe>tomorrow", "plesse>please", "thamks>thanks", "sorrt>sorry", "goinf>going", "meeyimg>meeting",
                      "realky>really", "agaun>again", "wprk>work", "frirnd>friend", "peopke>people", "jusy>just", "abour>about",
                      "wiyh>with"]),
            ("missing", ["tomorow>tomorrow", "probaly>probably", "becuse>because", "diferent>different", "realy>really",
                         "goverment>government", "wich>which", "thnk>think", "remeber>remember", "begining>beginning",
                         "Febuary>February", "occured>occurred"]),
            ("extra", ["untill>until", "allways>always", "thhe>the", "andd>and", "helllo>hello", "whatt>what"]),
            ("transposition", ["teh>the", "adn>and", "taht>that", "recieve>receive", "beleive>believe", "freind>friend",
                               "wierd>weird", "jsut>just", "konw>know", "thier>their", "hte>the"]),
            ("double", ["definately>definitely", "accomodate>accommodate", "neccessary>necessary", "tommorow>tomorrow",
                        "embarass>embarrass"]),
            ("apostrophe", ["dont>don't", "didnt>didn't", "doesnt>doesn't", "isnt>isn't", "wasnt>wasn't", "couldnt>couldn't",
                            "shouldnt>shouldn't", "youre>you're", "theyre>they're", "thats>that's", "whats>what's",
                            "wouldnt>wouldn't", "havent>haven't", "arent>aren't", "im>I'm"]),
            ("case", ["i>I", "london>London", "monday>Monday"]),
            ("variety", ["the color>colour", "my favorite>favourite", "center>centre", "theater>theatre", "neighbor>neighbour"]),
        ],
        .sqXK: [
            ("accent", ["eshte>është", "cfare>çfarë", "pershendetje>përshëndetje", "mire>mirë", "une>unë", "shume>shumë",
                        "nese>nëse", "dicka>diçka", "keshtu>kështu", "neser>nesër", "cka>çka", "ndihme>ndihmë", "gjithe>gjithë",
                        "kete>këtë", "vetem>vetëm", "gjate>gjatë", "shtepi>shtëpi", "femije>fëmijë", "mengjes>mëngjes",
                        "zemer>zemër", "ate>atë", "nje>një", "ketu>këtu", "Prishtine>Prishtinë", "Kosove>Kosovë",
                        "Shqiperi>Shqipëri", "pergjigje>përgjigje", "perse>përse", "gezuar>gëzuar", "mesim>mësim",
                        "ceshtje>çështje", "cdo>çdo", "qe>që"]),
            ("slip", ["faleminderjt>faleminderit", "tsni>tani", "ksfe>kafe", "ndoshra>ndoshta", "pastsj>pastaj",
                      "dashzri>dashuri", "falemindetit>faleminderit", "shkilla>shkolla", "qytrti>qyteti", "vajzs>vajza",
                      "djsli>djali", "nuj>nuk", "kuah>kush"]),
            ("missing", ["faleminerit>faleminderit", "ndosta>ndoshta", "shkola>shkolla", "pastj>pastaj"]),
            ("extra", ["tanii>tani", "kaffe>kafe", "nukk>nuk"]),
            ("transposition", ["kfae>kafe", "sthepi>shtëpi", "atni>tani"]),
        ],
        .itIT: [
            ("accent", ["perche>perché", "citta>città", "cosi>così", "puo>può", "lunedi>lunedì", "venerdi>venerdì",
                        "universita>università", "felicita>felicità", "qualita>qualità", "caffe>caffè", "poiche>poiché",
                        "finche>finché", "virtu>virtù", "societa>società", "realta>realtà", "possibilita>possibilità",
                        "liberta>libertà", "cioe>cioè", "perchè>perché", "piu>più", "gia>già", "verra>verrà"]),
            ("slip", ["grazue>grazie", "beme>bene", "sobo>sono", "domsni>domani", "anfiamo>andiamo", "vediamp>vediamo",
                      "allpra>allora", "qiesto>questo", "mangiaee>mangiare", "lsvoro>lavoro", "fsmiglia>famiglia",
                      "stasers>stasera", "aepetta>aspetta", "tutro>tutto", "nienre>niente", "voglip>voglio"]),
            ("missing", ["bongiorno>buongiorno", "domni>domani", "sempe>sempre", "qualcoa>qualcosa", "andimo>andiamo",
                         "macchna>macchina", "stamatina>stamattina", "settimna>settimana", "dovrebe>dovrebbe"]),
            ("double", ["aspeto>aspetto", "tuto>tutto", "ragazo>ragazzo", "piza>pizza", "dopio>doppio", "fratelo>fratello",
                        "sorela>sorella", "picolo>piccolo", "adeso>adesso"]),
            ("extra", ["graziee>grazie", "dovve>dove", "anccora>ancora"]),
            ("transposition", ["ocme>come", "qeusto>questo", "nache>anche", "grzaie>grazie", "dmoani>domani"]),
        ],
    ]

    // MARK: Completions (prefix → word that must be in the bar)

    static let completions: [KeyboardLanguage: [String]] = [
        .deAT: ["Entschuldi>Entschuldigung", "wahrsch>wahrscheinlich", "vielle>vielleicht", "eigent>eigentlich",
                "Geburt>Geburtstag", "Frühst>Frühstück", "zusamm>zusammen", "natürl>natürlich", "bissch>bisschen",
                "Österr>Österreich", "Nachri>Nachricht", "Weihna>Weihnachten", "funktion>funktioniert", "Wochenen>Wochenende",
                "Schwier>Schwierigkeiten", "überha>überhaupt", "verstan>verstanden"],
        .enGB: ["tomor>tomorrow", "becau>because", "probab>probably", "differe>different", "everyth>everything",
                "somethi>something", "beautif>beautiful", "restaur>restaurant", "appoint>appointment", "unfortun>unfortunately",
                "absolu>absolutely", "remem>remember", "interesti>interesting", "tonig>tonight", "brea>break"],
        .sqXK: ["faleminde>faleminderit", "përshën>përshëndetje", "ndosh>ndoshta", "pasta>pastaj", "dashur>dashuri",
                "shtëp>shtëpi", "gjithmo>gjithmonë", "mëngj>mëngjes", "Prisht>Prishtinë", "fëmij>fëmijë",
                "nesë>nesër", "vëlla>vëllai", "shkoll>shkolla", "mirëdi>mirëdita"],
        .itIT: ["buongio>buongiorno", "stase>stasera", "soprat>soprattutto", "qualc>qualcosa",
                "macchi>macchina", "ragaz>ragazzi", "famigl>famiglia", "ristora>ristorante", "appunt>appuntamento",
                "sicurame>sicuramente", "probabilm>probabilmente", "veramen>veramente", "aspet>aspetta", "complea>compleanno"],
    ]

    // MARK: Predictions (previous words → any of these in the three predictions)

    /// Sanity cases the bundled bigrams (Google Books) support; conversational pairs such as "guten" →
    /// "Morgen" are missing from that source (see the open issues in the engine quality report).
    static let predictionCases: [KeyboardLanguage: [([String], [String])]] = [
        .deAT: [(["ich"], ["bin", "habe", "hab", "glaube", "weiß", "will", "kann"]), (["vielen"], ["Dank", "dank"]),
                (["bis"], ["morgen", "dann", "später", "zum", "zur", "zu"]), (["es"], ["ist", "war", "gibt"]),
                (["das"], ["ist", "war", "Haus"]), (["nicht"], ["mehr", "nur", "so", "zu"])],
        .enGB: [(["thank"], ["you"]), (["in"], ["the", "a"]), (["how"], ["to", "much", "many", "are", "do"]),
                (["I"], ["am", "have", "was", "think", "don't"]), (["would"], ["be", "have", "like"]), (["of"], ["the", "a"])],
        .itIT: [(["non"], ["è", "ho", "so", "si"]), (["ti"], ["amo", "voglio", "ho", "ha", "sei"]), (["per"], ["la", "il", "me", "un"]),
                (["che"], ["non", "si", "è", "il"])],
    ]

    // MARK: Valid words that must never be autocorrected

    /// Names, places, brands and internet slang (typed in their usual form) — checked with every language set.
    static let sharedValidWords: [String] = [
        "Senad", "Arben", "Ardita", "Lukas", "Wien", "Prishtina", "Graz", "Linz", "Salzburg", "Tirana", "Prizren",
        "Blerim", "Besnik", "Dardan", "Drita", "Valon", "Vjosa", "Leutrim", "Edona", "Liridona", "Bujar", "Agon",
        "Granit", "Hamza", "Elias", "Lena", "Sophie", "Jonas", "Giulia", "Matteo",
        "WhatsApp", "iPhone", "iPad", "iCloud", "AirPods", "MacBook", "YouTube", "TikTok", "PayPal", "PlayStation",
        "Instagram", "Netflix", "Spotify", "Google", "Billa", "Hofer", "Lidl", "Samsung",
        "okay", "ok", "lol", "haha", "omg", "xD", "thx", "idk", "btw",
    ]

    static let curated: [KeyboardLanguage: [String]] = [
        .deAT: ["leiwand", "oida", "heast", "baba", "gemma", "Servus", "servus", "Bussi", "fesch", "Hawara", "Schmäh", "deppat",
                "bissl", "Gaudi", "Tschick", "schiach", "Öffis", "Spritzer", "Krügerl", "Beisl", "Jause", "Sackerl", "Semmel",
                "Paradeiser", "Topfen", "Marille", "heuer", "Jänner", "Feber", "Obers", "Kren", "Karfiol", "Fisolen", "Ribisel",
                "Zuckerl", "Würstel", "Pickerl", "Trafik", "Spital", "Matura", "Heuriger", "griaß", "pfiat", "passt", "geil",
                "krass", "Alter", "Handy", "nix", "eh", "halt", "mal", "gell", "achso", "egal", "mega", "chillen", "hob", "ned",
                "Wappler", "Schas", "hamma", "gehma", "nimma", "scho", "ois", "oiso", "wos", "voi", "digga", "vllt", "lg", "hdl",
                "mfg", "sry", "jo", "joa", "jap", "nö", "ähm", "mhm", "hmm", "Senad", "Arben", "Ardita", "Lukas", "Wien", "Graz"],
        .enGB: ["gonna", "wanna", "gotta", "dunno", "lemme", "yeah", "yep", "nope", "nah", "bro", "cool", "nice", "sorry",
                "colour", "favourite", "realise", "centre", "mum", "cheers", "mate", "innit", "telly", "uni", "pls", "plz",
                "ty", "np", "tbh", "imo", "brb", "wtf", "ffs", "bruh", "London", "Manchester", "Senad", "Arben", "Lukas"],
        .sqXK: ["faleminderit", "përshëndetje", "flm", "pse", "kur", "edhe", "tani", "sot", "nesër", "mirëdita", "mirëmbrëma",
                "natën", "urime", "gëzuar", "shyqyr", "inshallah", "vallahi", "bre", "ore", "çka", "qka", "qysh", "kqyr", "shpi",
                "bash", "hajde", "tung", "ckemi", "çkemi", "nana", "baba", "motra", "vëllai", "Prishtina", "Prizren", "Peja",
                "Gjakova", "Ferizaj", "Mitrovica", "Tirana", "Kosova", "Shqipëria", "Arben", "Ardita", "Senad", "Blerim",
                "Besnik", "Drita", "Valon", "Vjosa", "Fatmir", "Shqipe"],
        .itIT: ["ciao", "grazie", "prego", "allora", "boh", "dai", "vabbè", "cioè", "magari", "comunque", "tipo", "mamma",
                "papà", "nonna", "caffè", "pizza", "Milano", "Roma", "Napoli", "Torino", "Giulia", "Matteo", "Francesca", "Luca",
                "Andrea", "Marco", "Senad", "Arben", "Lukas", "ok", "okay"],
    ]

    /// More names, places, slang and brands (lower-case as typed in chats), used as a validation set
    /// when the thresholds were tuned on the lists above.
    static let validationValidWords: [String] = [
        "Fitim", "Ilir", "Arta", "Teuta", "Dafina", "Rinor", "Lirim", "Jeton", "Kushtrim", "Albin", "Ermal", "Shpend",
        "Donika", "Mimoza", "Flaka", "Erza", "Arlind", "Driton", "Valbona", "Besa", "Genc", "Gent", "Dren", "Tringa",
        "Rina", "Fjolla", "Ylli", "Emin", "Selim", "Zana", "Alban", "Gzim", "Ottakring", "Favoriten", "Floridsdorf",
        "Simmering", "Mödling", "Wels", "Steyr", "Villach", "Klagenfurt", "Bregenz", "Dornbirn", "Leoben", "Gmunden",
        "kk", "jaa", "nee", "jop", "jein", "safe", "sheesh", "yolo", "omw", "rn", "tmrw", "lmao", "lmk", "smh", "ngl",
        "fr", "srsly", "bc", "cuz", "coz", "tho", "thru", "ur", "gn", "gm", "hbd", "ily", "xoxo", "asap", "fyi",
        "aight", "qysh", "kqyre", "hajt", "tash", "spo", "sbon", "naj", "veq", "insta", "snap", "ikea", "zara", "dm",
        "bipa", "obi", "willhaben", "orf", "wlan", "pdf", "usb", "app", "apps", "emoji", "selfie", "googeln", "chatten",
        "hackln", "gspritzter", "eig", "vlt", "gibts", "gehts", "hab", "is", "nimmer", "gscheit", "fladern", "papperlapapp",
    ]
}

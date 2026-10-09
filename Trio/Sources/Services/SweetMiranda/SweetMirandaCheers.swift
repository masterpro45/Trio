import Foundation

/// Everything Luna says.
///
/// Wilson, 2026-10-08: *"bring luna inside, give her high fives and encouragement for her sugar
/// management… pop ups from luna in a corner that she can move around."*
///
/// ## Rules these lines live by
/// - ⚕️ **Luna never gives a medical instruction.** Not a dose, not a number to aim at, not
///   "eat something", not "check again". She is a dog who is proud of her girl. Treatment is her
///   parents' and her endocrinologist's, and nothing on this screen may blur that.
/// - **She never scolds.** A high or a low is not a failure, and the lines for those moments
///   comfort; they never grade. Diabetes is not something Miranda is doing wrong.
/// - **Short.** They sit in a speech bubble on a phone — roughly 70 characters.
/// - **No repeats.** `SweetMirandaCheers.next` draws from a shuffled bag per moment and only
///   reshuffles once the bag is empty, so a line can't come back until every sibling has had a turn.
enum SweetMirandaCheers {
    /// The moments Luna has something to say about. Order here is not priority — that lives in
    /// `SweetMirandaLuna`.
    enum Moment: String, CaseIterable {
        case hello
        case steady
        case longHaul
        case backInRange
        case lowOver
        case highNow
        case lowNow
        case dosed
        case carbs
        case podFresh
        case sensorFresh
        case morningWin
        case nightSteady
        case highFive
        case justBecause
    }

    /// One line for this moment, never the same one twice until the bag runs out.
    static func next(_ moment: Moment, defaults: UserDefaults = .standard) -> String {
        let pool = lines(moment)
        guard !pool.isEmpty else { return "" }
        let key = "sweetMiranda.luna.bag.\(moment.rawValue)"
        var bag = defaults.array(forKey: key) as? [Int] ?? []
        bag = bag.filter { $0 >= 0 && $0 < pool.count }
        if bag.isEmpty { bag = Array(pool.indices).shuffled() }
        let pick = bag.removeFirst()
        defaults.set(bag, forKey: key)
        return pool[pick]
    }

    /// How many lines Luna knows, for the count shown in her settings row.
    static var total: Int { Moment.allCases.reduce(0) { $0 + lines($1).count } }

    // swiftlint:disable function_body_length
    static func lines(_ moment: Moment) -> [String] {
        switch moment {
        case .hello:
            return [
                "There you are. I was watching the door.",
                "Hi! I kept your spot warm.",
                "You opened the app, so I opened one eye.",
                "Hello hello hello. That's three hellos.",
                "I barked at a squirrel for you today.",
                "My tail started before my eyes did.",
                "You're back! Nothing happened. I checked twice.",
                "I have been a very good dog, waiting.",
                "Hi. Nothing to report. Everything is fine.",
                "I sat right here the whole time. Mostly.",
                "You smell like outside. I approve.",
                "Checking in on me? Sweet. I'm great.",
                "I saved you the good cushion.",
                "Two taps and I'd have come to find you.",
                "Hi, best girl.",
                "I was going to nap, but then you showed up.",
                "You and me. That's the whole team.",
                "I don't know what day it is. You do. Good.",
                "You came back. You always come back.",
                "Woof. That one means hello."
            ]

        case .steady:
            return [
                "Smooth couple of hours. I noticed.",
                "Nice and level. Like a good nap.",
                "Steady. That's the hard one, and you did it.",
                "Two flat hours. Chef's kiss. Paw's kiss.",
                "Nothing exciting happened and that's the best news.",
                "You've been in your lane for hours. Proud.",
                "Boring numbers. My favorite kind.",
                "Flat line, happy dog.",
                "This is the good stretch. Enjoy it.",
                "Quiet afternoon for both of us.",
                "I'd give you a treat if I had thumbs.",
                "You made the boring kind of magic.",
                "No drama. Just you, doing it.",
                "Steady is a skill. You have it.",
                "I've been watching. Lovely work.",
                "Calm numbers, calm dog.",
                "That's hours of in-range. Hours!",
                "Somebody's been paying attention. It's you.",
                "Nice and even. Like your part in your hair.",
                "This stretch? Keep this stretch.",
                "You and the line are getting along today.",
                "Holding steady. That's not luck, that's you.",
                "The graph looks like a sidewalk. I love sidewalks.",
                "Two hours, no wobbles. Big deal, actually.",
                "I'm telling everyone about this.",
                "Smooth. Like the floor I slide on.",
                "You're making this look easy. It isn't.",
                "That's a nice shape on the chart.",
                "Still in range. Still impressed.",
                "Good hours happen. This is one."
            ]

        case .longHaul:
            return [
                "Six hours in range. SIX. I counted on my paws.",
                "That's half a day of steady. Enormous.",
                "You've been in range longer than my longest nap.",
                "Half a day of smooth. I'm beside myself.",
                "This is a record-shaped afternoon.",
                "Hours and hours of in-range. Let it sink in.",
                "I would wag this hard for nothing less.",
                "That's a long, lovely flat stretch. Nice.",
                "Big one. Hours of staying right where you want.",
                "I'm not crying, I'm a dog.",
                "This is the kind of day worth remembering.",
                "Long haul. You walked the whole way.",
                "Someone get this girl a medal. And me a snack.",
                "That's a whole lot of good hours in a row.",
                "Look at that. Just look at it.",
                "Stretches like this are why I believe in you.",
                "Hours of steady is not an accident.",
                "I've been wagging since lunch.",
                "That's the long smooth one. Those are rare.",
                "Whatever you did today — that. Remember that."
            ]

        case .backInRange:
            return [
                "You came back down. Good landing.",
                "Back in range. I never doubted you.",
                "There it is. Right back where you like it.",
                "You rode that one out. Nicely done.",
                "Down and steady. That was patient work.",
                "Back in your lane. Welcome home.",
                "That high didn't stand a chance.",
                "Settled. Deep breath. Good.",
                "You waited it out instead of panicking. Big deal.",
                "Back where you want to be. I'm wagging.",
                "That one took a while and you stayed calm.",
                "Nice and back. That's the whole trick.",
                "You brought it home. I'm proud of you.",
                "The number came down and you stayed you.",
                "Rough patch, handled.",
                "Back in range and I'm doing a little spin.",
                "You didn't give up on that one.",
                "That's what coming back looks like.",
                "All settled. That was good work.",
                "You're back. That was the hard part.",
                "I watched the whole thing. You were great.",
                "Sorted. Onwards.",
                "That curve came down beautifully.",
                "Patience works. You just proved it.",
                "Right back where you belong."
            ]

        case .lowOver:
            return [
                "You're back up. That was scary and you're okay.",
                "There you are again. I was close by.",
                "Back up and steady. Breathe.",
                "That's over now. You handled it.",
                "You came through it. Sit with me a minute.",
                "Up and safe. That's all I wanted.",
                "I stayed right here the whole time.",
                "That one was no fun. You're okay now.",
                "Back in range. Take it slow for a bit.",
                "You're alright. I can tell from here.",
                "Lows are rude. You were braver.",
                "All the way back. Good.",
                "That's behind you now.",
                "You're safe. That's the only number I care about.",
                "Back up. I'd lick your face if I could.",
                "Nothing to prove. You just got through it.",
                "Rough one. You're okay. Both true.",
                "I'm leaning on you a little.",
                "You're back and that's enough for today.",
                "Steady again. Well done, you."
            ]

        case .highNow:
            return [
                "Running high right now. It happens. You're still you.",
                "Numbers go up sometimes. Not your fault.",
                "A high is just a high. We wait it out together.",
                "I'm here. This part is annoying, not forever.",
                "You didn't break anything. Bodies do this.",
                "High day. Still my favorite person.",
                "This will come down. It always does.",
                "Nobody's keeping score. Especially not me.",
                "Sitting with you through this one.",
                "Highs are boring, not bad. You're doing fine.",
                "I don't love this number either. I love you.",
                "Hormones, growth spurts, pizza, weather. Not you.",
                "Stay patient with yourself. I am.",
                "You've come down from higher. I remember.",
                "This is a moment, not a verdict.",
                "I'll keep you company till it drops.",
                "No lecture from me. Just company.",
                "Diabetes is being loud today. You're louder.",
                "You're allowed to be annoyed. I'm annoyed with you.",
                "Head up. The line always comes back.",
                "One number. That's all this is.",
                "Still the same brilliant girl as this morning.",
                "We've been here before and it passed.",
                "I'm not going anywhere.",
                "You're carrying something heavy today. I see it."
            ]

        case .lowNow:
            return [
                "I'm right here with you.",
                "Low. Sit down a second. I'll stay.",
                "You're not alone in this one.",
                "Nothing else matters right now. Just this.",
                "I've got you. Take your time.",
                "Lean on something. I've got the watching part.",
                "Stay put with me a minute.",
                "Your people know. You're not on your own.",
                "This passes. I'll be here when it does.",
                "No rush, no fuss. Just sit.",
                "I'd carry you if I were bigger.",
                "Easy. Slow. I'm not moving.",
                "You're okay. I'm right next to you.",
                "Head down, I'll keep watch.",
                "Just breathe. That's the whole job right now.",
                "I'm not leaving this spot.",
                "Nothing to do but wait with me.",
                "You're being taken care of. Promise.",
                "Quiet for a bit. I like quiet.",
                "Close by. Always close by."
            ]

        case .dosed:
            return [
                "You took care of that yourself. Look at you.",
                "Handled. I saw the whole thing.",
                "That's you, looking after you.",
                "Done and done. High five incoming.",
                "You didn't put it off. That's the win.",
                "Taken care of. Nice.",
                "Smooth. Like you've done it a thousand times.",
                "You remembered. That's not nothing.",
                "Sorted it without being asked. Proud.",
                "That's grown-up stuff you just did.",
                "One less thing. Good.",
                "You looked after yourself. I noticed.",
                "Quick and calm. My favorite combination.",
                "Did it, didn't make a fuss. Classic you.",
                "Taken care of before it became a problem.",
                "That was the responsible thing and you just did it.",
                "No reminding needed. None.",
                "Look at that. All by yourself.",
                "You run your own show. It shows.",
                "Handled it like it was easy.",
                "That's a hundred tiny decisions a day. You made one.",
                "Done. Go be a kid now.",
                "I'd be lost without you, honestly.",
                "On it before I even looked up.",
                "You are so much better at this than you think."
            ]

        case .carbs:
            return [
                "Food logged. Was it good? Looked good.",
                "You wrote it down. That's the hard half.",
                "Noted. Did you save me any?",
                "Logged it before eating. Discipline!",
                "I smelled that from here.",
                "Nice. The app knows, so you don't have to remember.",
                "Typed it in without being told. Love that.",
                "Enjoy your food. Seriously, enjoy it.",
                "Logged. Now go eat it while it's warm.",
                "Every time you log, future-you says thanks.",
                "That's the step everybody skips. You didn't.",
                "Counted and sorted. Go enjoy.",
                "Food is supposed to be fun. Have fun.",
                "Down in the book. Good girl — wait, that's my line.",
                "You handled the boring part first. Respect."
            ]

        case .podFresh:
            return [
                "New pod on. That's three days sorted.",
                "Fresh pod! The annoying job is done.",
                "Changed it on time. Big, big deal.",
                "New pod, clean slate.",
                "That's the one that matters and you did it.",
                "Pod swapped. Nothing to think about now.",
                "On time. I'm telling your dad.",
                "New pod. You beat the clock.",
                "Done before it ran out. That's the whole game.",
                "Fresh start on your side.",
                "Pod change done. Go do something fun.",
                "Right on schedule. Look at you.",
                "That's the chore nobody thanks you for. Thank you.",
                "New pod humming along. All good.",
                "Changed it yourself. Proud doesn't cover it."
            ]

        case .sensorFresh:
            return [
                "New sensor in. Ten days of seeing you.",
                "Fresh sensor. I can watch you properly again.",
                "Sensor changed on time. Gold star.",
                "New sensor, new numbers. Good job.",
                "That stings for a second and then it's done.",
                "Done! Warm-up now, then we're back.",
                "Sensor sorted. That was brave.",
                "New one in before the old one quit. Nice.",
                "Ten more days of me keeping an eye on you.",
                "Changed it without a fuss. Noted.",
                "Fresh sensor. Clean data. Happy dog.",
                "That's the hard one and it's behind you.",
                "Right on time. Every time lately.",
                "New sensor. Go wash your hands and relax.",
                "I never like that bit. You were tough."
            ]

        case .morningWin:
            return [
                "You woke up in range. What a way to start.",
                "Good morning! The night went well.",
                "Morning. You slept and the numbers behaved.",
                "Woke up steady. That's a gift of a morning.",
                "Nice night's work, and you were asleep for it.",
                "Morning, best girl. Lovely numbers.",
                "You start today already winning.",
                "I watched over you. Nothing to report.",
                "Steady all night. Go have breakfast.",
                "That's a good night on the chart.",
                "Morning! I've been awake since 5. No reason.",
                "You and the night got along. Rare and nice.",
                "Waking up in range is the best kind of luck and work.",
                "Fresh day, good start.",
                "Smooth night. Big day. Go on then.",
                "First thing I checked. It's all good.",
                "Yawn. Stretch. Nice numbers. In that order.",
                "The hard hours went fine. Have a great day.",
                "You earned an easy morning.",
                "Good morning. Nothing needs you yet."
            ]

        case .nightSteady:
            return [
                "Good evening's numbers. Sleep easy.",
                "Steady tonight. I'll keep one ear open.",
                "Nice evening. Go to bed proud.",
                "You handled today. All of it.",
                "Lights out soon? Numbers look kind.",
                "That was a good day's work.",
                "Evening's calm. So am I.",
                "I'm going to curl up now. You should too.",
                "Today was a good one. Say it out loud.",
                "Steady into the night. Lovely.",
                "You did a whole day of this. Again.",
                "Quiet evening. Those are the best ones.",
                "Nothing left to do today. Rest.",
                "Tomorrow's problem is tomorrow's.",
                "Goodnight soon, best girl.",
                "Smooth evening. I'm proud of you.",
                "You kept it together all day. I saw.",
                "Bed, book, dog. Perfect night.",
                "Day's done and it went well.",
                "Sleep well. I'm on watch."
            ]

        case .highFive:
            return [
                "HIGH FIVE! 🐾",
                "Paw! Right there. 🐾",
                "Boop. That's a paw bump.",
                "Five! Again? Again.",
                "You get a paw AND a tail wag.",
                "That's the good stuff. 🐾",
                "Hey! Nice paw.",
                "Up top! 🐾",
                "Double paw. Rare. You earned it.",
                "I've been saving that one.",
                "Paws up, best girl.",
                "That's my favorite button.",
                "Again! My paw's not tired.",
                "You, me, high five. Perfect system.",
                "Pow. Paw. Whatever.",
                "Soft paw, big feelings.",
                "That's a yes from me.",
                "Highest of fives.",
                "I'd do that all day.",
                "Tail: wagging. Paw: raised.",
                "You tapped me! Best part of my day.",
                "Five more where that came from.",
                "Paw five. Official.",
                "I was hoping you'd do that.",
                "Boop! Now go be amazing.",
                "That's two good dogs in one room.",
                "Nice one. I felt that.",
                "Hi! Hello! Paw!",
                "You're my person, you know.",
                "Right back at you. 🐾",
                "One paw, all my love.",
                "Wag wag wag wag wag.",
                "Teammates. 🐾",
                "I'll take a thousand of those.",
                "Yes! Exactly that!",
                "Paw received. Processing joy.",
                "Good tap. Very good tap.",
                "You've got a great high five.",
                "That's the whole reason I'm here.",
                "Five! Okay, now I'm going to spin."
            ]

        case .justBecause:
            return [
                "You know you're doing great, right?",
                "Just came to look at you.",
                "No reason. Just thought you should know you're loved.",
                "This is hard and you do it every single day.",
                "Nobody sees most of what you do. I do.",
                "You're more than your numbers. Way more.",
                "I'd follow you anywhere. Especially to the kitchen.",
                "You're allowed to be tired of this.",
                "Hey. You're great. That's all.",
                "Diabetes doesn't get a vote on who you are.",
                "I think about you when you're at school.",
                "One day at a time. You're doing the days.",
                "You're braver than most grown-ups I've met.",
                "Still proud. Didn't need a reason.",
                "I like your face.",
                "You're the best thing in this house.",
                "If you're having a hard day, that's allowed.",
                "Not a reminder. Just a hello.",
                "You handle more before breakfast than most people all day.",
                "I'd give you my favorite toy. The squeaky one.",
                "You don't have to be perfect at this. Nobody is.",
                "Thanks for taking care of you. It matters to me.",
                "You make this look manageable. It isn't. You just do.",
                "Some days you carry it, some days it carries you. Both fine.",
                "I'm on your team forever.",
                "Hey, you. Keep going. You're good at this.",
                "You're not behind. You're right here.",
                "Whatever today is, I'm in it with you.",
                "I don't understand any of the numbers. I understand you.",
                "You're doing it. That's the whole thing. You're doing it."
            ]
        }
    }

    // swiftlint:enable function_body_length
}

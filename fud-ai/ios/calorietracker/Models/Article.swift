import SwiftUI

enum ArticleCategory: String, CaseIterable {
    case nutrition = "Nutrition"
    case science = "Science"
    case lifestyle = "Lifestyle"
    case technology = "Technology"

    var color: Color {
        switch self {
        case .nutrition: return AppColors.protein
        case .science: return AppColors.calorie
        case .lifestyle: return AppColors.fat
        case .technology: return AppColors.carbs
        }
    }

    var gradient: [Color] {
        switch self {
        case .nutrition: return AppColors.proteinGradient
        case .science: return AppColors.calorieGradient
        case .lifestyle: return AppColors.fatGradient
        case .technology: return AppColors.carbsGradient
        }
    }
}

struct Article: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let summary: String
    let readingTimeMinutes: Int
    let category: ArticleCategory
    let imageURL: String
    let dateAdded: Date
    let content: String

    var contentParagraphs: [String] {
        content.components(separatedBy: "\n\n")
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: dateAdded)
    }

    static let allArticles: [Article] = [
        Article(
            icon: "flame.fill",
            title: "Calorie Tracking & BMR Formulas",
            summary: "Understand how your body burns energy and why BMR matters for your goals.",
            readingTimeMinutes: 4,
            category: .science,
            imageURL: "https://images.unsplash.com/photo-1509833903111-9cb142f644e4?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## What Are Calories?

            A calorie is a unit of energy. When we talk about the calories in food, we're really talking about kilocalories (kcal) — the amount of energy needed to raise one kilogram of water by one degree Celsius. Your body needs this energy for everything from breathing to running a marathon.

            ## Basal Metabolic Rate (BMR)

            Your BMR is the number of calories your body burns at complete rest — just to keep you alive. It powers your heartbeat, brain activity, cell repair, and breathing. BMR typically accounts for 60-75% of your total daily energy expenditure.

            ## How BMR Is Calculated

            There are two popular formulas. The Mifflin-St Jeor equation uses your weight, height, age, and sex to estimate BMR. It's accurate for most people. The Katch-McArdle formula uses lean body mass instead, making it more precise if you know your body fat percentage. This app uses Katch-McArdle when body fat data is available, and Mifflin-St Jeor otherwise.

            ## From BMR to TDEE

            Your Total Daily Energy Expenditure (TDEE) is your BMR multiplied by an activity factor. A sedentary person might multiply by 1.2, while a very active athlete could use 1.9 or higher. TDEE represents the total calories you burn in a day including exercise and daily movement.

            ## Why This Matters for You

            To lose weight, you eat below your TDEE. To gain weight, you eat above it. A deficit of about 500 calories per day leads to roughly 0.5 kg of weight loss per week. Understanding your BMR and TDEE helps you set realistic, sustainable calorie targets rather than guessing.
            """
        ),

        Article(
            icon: "chart.pie.fill",
            title: "Understanding Macronutrients",
            summary: "Learn about protein, carbs, and fat — the three building blocks of every meal.",
            readingTimeMinutes: 5,
            category: .nutrition,
            imageURL: "https://images.unsplash.com/photo-1512621776951-a57141f2eefd?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## The Big Three

            Every food you eat is made up of three macronutrients: protein, carbohydrates, and fat. Each plays a distinct role in your body. While calories tell you how much energy a food provides, macros tell you where that energy comes from and how your body will use it.

            ## Protein: The Builder

            Protein provides 4 calories per gram. It's essential for building and repairing muscle, producing enzymes and hormones, and supporting immune function. Good sources include chicken, fish, eggs, dairy, legumes, and tofu. Most adults need 0.8-1.2 grams per kilogram of body weight, though athletes and those building muscle may need more.

            ## Carbohydrates: The Fuel

            Carbs also provide 4 calories per gram. They're your body's preferred energy source, especially for your brain and during high-intensity exercise. Complex carbs like whole grains, vegetables, and fruits provide sustained energy along with fiber and vitamins. Simple carbs like sugar provide quick energy but less nutritional value.

            ## Fat: The Essential

            Fat provides 9 calories per gram — more than double the other macros. It's vital for hormone production, vitamin absorption (A, D, E, K), brain health, and cell membrane structure. Healthy fats from avocados, nuts, olive oil, and fatty fish are important parts of a balanced diet.

            ## Finding Your Balance

            This app uses a balanced split: 30% of calories from protein, 45% from carbs, and 25% from fat. This works well for most people, but the ideal ratio depends on your goals. Athletes might want more protein, endurance athletes more carbs, and those on keto significantly more fat.

            ## Tracking Makes It Real

            Most people dramatically underestimate their fat intake and overestimate their protein. Tracking macros for even a few weeks builds awareness of what's actually in your food, helping you make better choices even after you stop tracking.
            """
        ),

        Article(
            icon: "leaf.fill",
            title: "The Hidden World of Micronutrients",
            summary: "Vitamins and minerals are tiny but mighty — here's why they matter.",
            readingTimeMinutes: 4,
            category: .nutrition,
            imageURL: "https://images.unsplash.com/photo-1557844352-761f2565b576?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## Beyond Macros

            While macronutrients get most of the attention, micronutrients — vitamins and minerals — are equally critical. They don't provide calories, but without them, your body can't convert food into energy, build bone, fight infection, or repair DNA.

            ## Key Vitamins

            Vitamin D supports bone health and immune function. Many people are deficient, especially those who live far from the equator. Vitamin B12 is crucial for nerve function and red blood cell formation — vegans need to supplement it. Vitamin C supports immune health and collagen production, found abundantly in citrus fruits and bell peppers.

            ## Essential Minerals

            Iron carries oxygen in your blood. Low iron leads to fatigue and weakness. Calcium builds strong bones and teeth. Magnesium supports over 300 enzyme reactions, including muscle and nerve function, yet most people don't get enough. Zinc supports immune function and wound healing.

            ## Eating the Rainbow

            The simplest way to cover your micronutrient bases is to eat a variety of colorful fruits and vegetables. Different colors indicate different phytonutrients: red tomatoes provide lycopene, orange carrots offer beta-carotene, green spinach delivers folate and iron, and blueberries pack anthocyanins.

            ## When to Supplement

            A balanced diet usually provides adequate micronutrients. However, certain groups may benefit from supplements: vegans (B12, iron), people with limited sun exposure (vitamin D), pregnant women (folate), and older adults (calcium, D, B12). Always consult a healthcare provider before starting supplements.
            """
        ),

        Article(
            icon: "scalemass.fill",
            title: "The Science of Weight Loss",
            summary: "Why sustainable weight loss is a marathon, not a sprint.",
            readingTimeMinutes: 5,
            category: .science,
            imageURL: "https://images.unsplash.com/photo-1611077544695-c7942e060c4d?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## Energy Balance

            Weight loss fundamentally comes down to energy balance: consuming fewer calories than you burn. One kilogram of body fat stores roughly 7,700 calories. To lose 0.5 kg per week, you need a daily deficit of about 550 calories. This app calculates your ideal deficit based on your goals.

            ## Why Crash Diets Fail

            Severe calorie restriction triggers adaptive thermogenesis — your body lowers its metabolic rate to conserve energy. This means you burn fewer calories at rest, making further weight loss harder. You also lose more muscle mass, which further reduces metabolism. A moderate deficit of 300-750 calories per day preserves muscle and keeps your metabolism healthy.

            ## The Role of Protein

            During a calorie deficit, adequate protein intake is crucial. Protein helps preserve lean muscle mass, keeps you feeling full longer, and has a higher thermic effect — your body burns more calories digesting protein than carbs or fat. Aim for at least 1.6 grams per kilogram of body weight when losing weight.

            ## Water Weight vs. Fat Loss

            The scale can fluctuate 1-2 kg daily due to water retention, sodium intake, carb intake, and digestive contents. This is why weekly averages matter more than daily weigh-ins. Real fat loss happens gradually — about 0.5-1 kg per week is a healthy, sustainable rate.

            ## Plateaus Are Normal

            After weeks of consistent weight loss, your body adapts. Your smaller body requires fewer calories, and metabolic adaptation reduces energy expenditure. Breaking through plateaus may require recalculating your TDEE, adjusting your calorie target, increasing activity, or simply being patient. The scale will move again.

            ## Building Habits

            The most effective diet is one you can maintain. Focus on building sustainable habits: cooking more meals at home, eating enough protein, finding physical activities you enjoy, and getting adequate sleep. Small, consistent changes outperform dramatic overhauls every time.
            """
        ),

        Article(
            icon: "camera.viewfinder",
            title: "How AI Photo Tracking Works",
            summary: "Point, snap, log — how this app uses AI to identify your food.",
            readingTimeMinutes: 3,
            category: .technology,
            imageURL: "https://images.unsplash.com/photo-1578157300519-5b1ca459b218?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## Snap and Track

            Traditional food logging means searching databases, estimating portions, and manually entering numbers. AI photo tracking simplifies this: take a photo of your meal, and the AI identifies the food, estimates portions, and calculates nutrition — all in seconds.

            ## How It Works

            When you snap a photo, the image is sent to Google's Gemini AI model. The model has been trained on millions of food images and nutritional databases. It identifies individual food items in your photo, estimates serving sizes based on visual cues, and returns calorie and macronutrient estimates.

            ## Accuracy and Limitations

            AI food recognition is impressive but not perfect. It works best with clearly visible, common foods. Dense mixed dishes like casseroles or heavily sauced foods are harder to analyze accurately. The estimates are good starting points — you can always adjust the values before logging.

            ## Nutrition Labels

            For packaged foods, the app can also read nutrition labels. Just switch to label mode and photograph the nutrition facts panel. The AI extracts the exact values printed on the label, which is more accurate than visual food estimation.

            ## Tips for Better Results

            For the best accuracy, photograph your food from above with good lighting. Spread items apart so the AI can distinguish them. Include common objects for scale reference. And remember — even imperfect tracking is far better than no tracking at all.
            """
        ),

        Article(
            icon: "fork.knife",
            title: "Keto & Low-Carb Diets Explained",
            summary: "What happens when you drastically cut carbs from your diet.",
            readingTimeMinutes: 4,
            category: .nutrition,
            imageURL: "https://images.unsplash.com/photo-1501199951034-d79a3f2d3039?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## What Is Keto?

            The ketogenic diet drastically reduces carbohydrate intake to typically 20-50 grams per day, replacing those calories with fat and moderate protein. This forces your body to switch from burning glucose to burning fat for fuel — a metabolic state called ketosis.

            ## How Ketosis Works

            Normally, your body breaks down carbs into glucose for energy. When carbs are severely restricted, your liver converts fatty acids into ketone bodies, which your brain and muscles can use as an alternative fuel source. This transition typically takes 2-7 days and may cause temporary symptoms known as the "keto flu."

            ## Potential Benefits

            Many people report reduced hunger on keto because fat and protein are highly satiating. Blood sugar levels tend to stabilize, which can benefit those with insulin resistance. Some studies show faster initial weight loss, though much of the early loss is water weight as glycogen stores are depleted.

            ## Important Considerations

            Keto eliminates many nutritious foods: most fruits, many vegetables, whole grains, and legumes. This can lead to fiber deficiency and missing micronutrients. The diet can be hard to sustain socially and may cause digestive changes. Athletic performance, especially for high-intensity exercise, may initially decrease.

            ## Is It Right for You?

            Low-carb diets work well for some people and poorly for others. The best diet is one that creates a sustainable calorie deficit while providing adequate nutrition. If you choose to try keto, track your macros carefully and ensure you're getting enough fiber and micronutrients from low-carb vegetables.
            """
        ),

        Article(
            icon: "bolt.fill",
            title: "Why Carbs Matter for Energy",
            summary: "Carbohydrates aren't the enemy — they're your body's premium fuel.",
            readingTimeMinutes: 4,
            category: .nutrition,
            imageURL: "https://images.unsplash.com/photo-1521471109507-43d61bb345dd?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## Your Body's Preferred Fuel

            Carbohydrates are your body's primary and preferred energy source. When you eat carbs, they're broken down into glucose, which powers every cell in your body. Your brain alone uses about 120 grams of glucose per day — roughly half of a typical person's carb intake.

            ## Simple vs. Complex

            Simple carbohydrates (sugars) are quickly digested, causing rapid blood sugar spikes and crashes. Complex carbohydrates (starches, fiber) break down slowly, providing sustained energy. Whole grains, vegetables, fruits, and legumes are excellent sources of complex carbs packed with fiber, vitamins, and minerals.

            ## The Fiber Factor

            Dietary fiber is a type of carbohydrate your body can't digest. Despite providing no calories, fiber is incredibly important. Soluble fiber slows digestion and helps control blood sugar. Insoluble fiber promotes healthy digestion. Most adults need 25-30 grams of fiber daily, but the average intake is only about 15 grams.

            ## Carbs and Exercise

            During moderate to high-intensity exercise, carbohydrates are your muscles' primary fuel. Glycogen — stored carbs in your muscles and liver — powers your workouts. Athletes and active people need more carbs to maintain performance and recover properly. Cutting carbs too low can leave you feeling tired and weak during exercise.

            ## The Bottom Line

            Carbs aren't inherently good or bad. The quality and quantity matter. Choose whole, minimally processed sources most of the time. This app tracks your carb intake as part of your overall macro balance, helping you fuel your body appropriately for your activity level and goals.
            """
        ),

        Article(
            icon: "figure.strengthtraining.traditional",
            title: "How Much Protein Do You Need?",
            summary: "The complete guide to daily protein intake for every goal.",
            readingTimeMinutes: 4,
            category: .nutrition,
            imageURL: "https://images.unsplash.com/photo-1600555379765-f82335a7b1b0?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## The Protein Debate

            Protein recommendations vary widely depending on who you ask. The minimum recommended daily allowance is 0.8 grams per kilogram of body weight, but research suggests most people benefit from significantly more, especially if they're active or trying to change their body composition.

            ## Protein for Muscle Building

            If you're strength training and want to build muscle, research consistently shows benefits from consuming 1.6-2.2 grams of protein per kilogram of body weight per day. Spreading protein intake across 3-5 meals optimizes muscle protein synthesis — your body can only use so much protein at once for muscle building.

            ## Protein for Weight Loss

            During a calorie deficit, higher protein intake (1.6-2.4 g/kg) helps preserve muscle mass that would otherwise be lost along with fat. Protein also has the highest satiety effect of any macronutrient, keeping you fuller for longer and reducing cravings. Its high thermic effect means you burn more calories digesting it.

            ## Best Protein Sources

            Animal sources like chicken breast, fish, eggs, and Greek yogurt provide complete proteins with all essential amino acids. Plant-based sources like lentils, chickpeas, tofu, tempeh, and quinoa can provide adequate protein when combined throughout the day. Variety is key for getting all essential amino acids.

            ## Timing Matters (A Little)

            While total daily protein intake matters most, distributing it evenly across meals is modestly beneficial. Having 20-40 grams of protein per meal supports continuous muscle protein synthesis. A protein-rich breakfast can also help control appetite throughout the day.

            ## Practical Tips

            Start by calculating your target based on your body weight and goals. Use this app to track whether you're hitting that target. If you consistently fall short, add a protein source to each meal: eggs at breakfast, chicken at lunch, fish at dinner. Small changes compound over time.
            """
        ),

        Article(
            icon: "brain.head.profile",
            title: "The Art of Mindful Eating",
            summary: "Slow down, savor your food, and transform your relationship with eating.",
            readingTimeMinutes: 4,
            category: .lifestyle,
            imageURL: "https://images.unsplash.com/photo-1520630086303-ccaa3cb0acef?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## What Is Mindful Eating?

            Mindful eating means paying full attention to the experience of eating — the flavors, textures, aromas, and sensations of your food. It's the opposite of mindlessly scrolling your phone while shoveling food down. This simple practice can transform your relationship with food and support your health goals.

            ## The Problem with Distracted Eating

            Studies show that eating while distracted — watching TV, working, or browsing your phone — leads to consuming 25-50% more calories. When your brain isn't focused on eating, it misses satiety signals. You eat faster, chew less, and often feel unsatisfied even after a large meal.

            ## How to Practice

            Start with one mindful meal per day. Put away your phone and turn off the TV. Before eating, take a breath and notice your hunger level on a scale of 1-10. Take smaller bites and chew thoroughly. Put your fork down between bites. Notice the flavors and textures. Check in with your hunger level halfway through the meal.

            ## Recognizing Hunger vs. Habit

            Many eating occasions aren't driven by true physical hunger. Boredom, stress, habit, and social situations all trigger eating. Before reaching for food, pause and ask: Am I physically hungry, or am I eating for another reason? This awareness alone can reduce unnecessary snacking significantly.

            ## Combining Tracking with Mindfulness

            Calorie tracking and mindful eating complement each other beautifully. Tracking builds awareness of what and how much you eat. Mindfulness builds awareness of why and how you eat. Together, they create a complete picture that supports lasting, healthy eating habits without the stress of rigid dieting.
            """
        ),

        Article(
            icon: "moon.zzz.fill",
            title: "Sleep and Its Impact on Health",
            summary: "Why quality sleep is the most underrated factor in weight management.",
            readingTimeMinutes: 4,
            category: .lifestyle,
            imageURL: "https://images.unsplash.com/photo-1531572753322-ad063cecc140?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## The Sleep-Weight Connection

            Sleep is arguably the most overlooked factor in weight management. Research shows that sleeping less than 7 hours per night increases hunger hormones, reduces willpower, impairs metabolism, and makes your body more likely to store fat rather than burn it.

            ## Hormonal Havoc

            Sleep deprivation increases ghrelin (the hunger hormone) by up to 28% and decreases leptin (the satiety hormone) by 18%. This hormonal shift makes you hungrier, crave high-calorie foods, and feel less satisfied after eating. One night of poor sleep can increase calorie intake by 300-400 calories the next day.

            ## Metabolism and Recovery

            During deep sleep, your body releases growth hormone, repairs muscle tissue, and regulates blood sugar. Chronic sleep deprivation reduces insulin sensitivity, making your body less efficient at processing carbohydrates. It also impairs muscle recovery after exercise, limiting the benefits of your workouts.

            ## Sleep Hygiene Basics

            Good sleep starts with consistency. Go to bed and wake up at the same time daily, even on weekends. Keep your bedroom cool (18-20°C), dark, and quiet. Avoid screens for 30-60 minutes before bed — blue light suppresses melatonin production. Limit caffeine after 2 PM and avoid large meals close to bedtime.

            ## The Bigger Picture

            Think of sleep as the foundation that supports all your other health efforts. Good sleep makes it easier to stick to your calorie goals, perform well in workouts, manage stress, and make healthy food choices. If you're doing everything right with diet and exercise but skimping on sleep, you're undermining your own progress.
            """
        ),

        Article(
            icon: "drop.fill",
            title: "Water and Hydration",
            summary: "How staying hydrated affects everything from energy to appetite.",
            readingTimeMinutes: 3,
            category: .lifestyle,
            imageURL: "https://images.unsplash.com/photo-1563733586325-5fb533331826?w=800&h=400&fit=crop",
            dateAdded: DateComponents(calendar: .current, year: 2026, month: 2, day: 8).date!,
            content: """
            ## Why Hydration Matters

            Water makes up about 60% of your body weight and is involved in virtually every bodily function. It transports nutrients, regulates temperature, cushions joints, and removes waste. Even mild dehydration — just 1-2% of body weight — can impair mood, concentration, and physical performance.

            ## Hydration and Hunger

            Thirst is often mistaken for hunger. Studies show that drinking a glass of water before meals reduces calorie intake by 75-90 calories per meal. Staying well-hydrated throughout the day can help prevent unnecessary snacking and support your calorie goals.

            ## How Much Do You Need?

            The classic "8 glasses a day" is a reasonable starting point but isn't based on strong science. A better guideline is to drink about 30-35 mL per kilogram of body weight daily. Active people, those in hot climates, and larger individuals need more. The simplest indicator is urine color — pale yellow means well-hydrated.

            ## Beyond Water

            While plain water is ideal, other beverages and foods contribute to hydration. Herbal tea, sparkling water, and milk all count. Fruits and vegetables like watermelon, cucumber, and oranges are 85-95% water. Coffee and tea have mild diuretic effects but still contribute net hydration when consumed in moderate amounts.

            ## Practical Tips

            Keep a water bottle with you throughout the day. Drink a glass of water when you wake up — you're mildly dehydrated after sleeping. Set reminders if you tend to forget. Add lemon, cucumber, or mint if you find plain water boring. And remember that if you're feeling tired or hungry, try water first.
            """
        ),
    ]
}

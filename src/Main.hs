{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE StrictData #-}

module Main
  (main)
where

import qualified BlueRipple.Tools.StateLeg.Analysis as BSL
import qualified BlueRipple.Configuration as BR
import qualified BlueRipple.Model.Election2.DataPrep as DP
import qualified BlueRipple.Model.Election2.ModelCommon as MC
import BlueRipple.Model.Election2.ModelCommon (ModelConfig)
import qualified BlueRipple.Model.Election2.ModelRunner as MR
import qualified BlueRipple.Model.CategorizeElection as CE

import qualified BlueRipple.Data.CachingCore as BRCC
import qualified BlueRipple.Utilities.KnitUtils as BRK
import qualified BlueRipple.Data.Types.Demographic as DT
import qualified BlueRipple.Data.Types.Geographic as GT
import qualified BlueRipple.Data.Types.Election as ET
import qualified BlueRipple.Data.Types.Modeling as MT
import qualified BlueRipple.Data.Small.Loaders as BRS
import qualified BlueRipple.Data.ACS_Tables as BRC
import qualified BlueRipple.Data.DistrictOverlaps as DO

import qualified Knit.Report as K
import qualified Knit.Effect.AtomicCache as KC
import qualified Text.Pandoc.Error as Pandoc
import qualified System.Console.CmdArgs as CmdArgs

import qualified Stan.ModelBuilder.TypedExpressions.Types as TE
import qualified Stan.ModelBuilder.DesignMatrix as DM

import qualified Frames as F
import qualified Frames.Constraints as FC
import qualified Frames.Streamly.CSV as FCSV
--import qualified Frames.Streamly.TH as FTH
import qualified Frames.Streamly.OrMissing as FOM

import Frames.Streamly.Streaming.Streamly (StreamlyStream, Stream)
import qualified Control.Foldl as FL
import Control.Lens (view, (^.))

import qualified Data.Map.Strict as M
import qualified Data.Vinyl as V
import qualified Data.Vinyl.TypeLevel as V
import qualified Data.Vinyl.Functor as V

import qualified Text.Printf as PF
import qualified System.Environment as Env

templateVars ∷ Map String String
templateVars =
  M.fromList
    [ ("lang", "English")
    , ("site-title", "Blue Ripple Politics")
    , ("home-url", "https://www.blueripplepolitics.org")
    --  , ("author"   , T.unpack yamlAuthor)
    ]

pandocTemplate ∷ K.TemplatePath
pandocTemplate = K.FullySpecifiedTemplatePath "pandoc-templates/blueripple_basic.html"

dmr ::  DM.DesignMatrixRow (F.Record DP.LPredictorsR)
dmr = MC.tDesignMatrixRow_d

survey :: MC.ActionSurvey (F.Record DP.CESByCDR)
survey = MC.CESSurvey (DP.AllSurveyed DP.Both)

aggregation :: MC.SurveyAggregation TE.EIntArray
aggregation = MC.UnweightedAggregation

alphaModel :: MC.Alphas
alphaModel = MC.St_A_S_E_R_StA_StS_StE_StR_AS_AE_AR_SE_SR_ER_StER --MC.St_A_S_E_R_AE_AR_ER_StR

type SLDKeyR = '[GT.StateAbbreviation] V.++ BRC.LDLocationR
type ModeledR = SLDKeyR V.++ '[MR.ModelCI]

main :: IO ()
main = do
  cmdLine ← CmdArgs.cmdArgsRun BR.commandLine
  pandocWriterConfig ←
    K.mkPandocWriterConfig
    pandocTemplate
    templateVars
    (BRK.brWriterOptionsF . K.mindocOptionsF)
  cacheDir <- toText . fromMaybe ".kh-cache" <$> Env.lookupEnv("BR_CACHE_DIR")
  let knitConfig ∷ K.KnitConfig BRCC.SerializerC BRCC.CacheData Text =
        (K.defaultKnitConfig $ Just cacheDir)
          { K.outerLogPrefix = Just "Gaba"
          , K.logIf = BR.knitLogSeverity $ BR.logLevel cmdLine -- K.logDiagnostic
          , K.lcSeverity = mempty --M.fromList [("KH_Cache", K.Special), ("KH_Serialize", K.Special)]
          , K.pandocWriterConfig = pandocWriterConfig
          , K.serializeDict = BRCC.flatSerializeDict
          , K.persistCache = KC.persistStrictByteString (\t → toString (cacheDir <> "/" <> t))
          }
  resE ← K.knitHtmls knitConfig $ do
    K.logLE K.Info $ "Command Line: " <> show cmdLine
    let postInfo = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes BR.Unpublished Nothing)
    lastPush
  case resE of
    Right namedDocs →
      K.writeAllPandocResultsWithInfoAsHtml "" namedDocs
    Left err → putTextLn $ "Pandoc Error: " <> Pandoc.renderError err

lpInCompetitiveCD :: FC.ElemsOf rs '[BSL.CDPPL, DO.Overlap] => F.Record rs -> Bool
lpInCompetitiveCD r = let ppl = r ^. BSL.cDPPL
                      in case ppl of
                           FOM.Missing -> False
                           FOM.Present x -> x >= 0.4 && x < 0.6 && r ^. DO.overlap >= 0.5

lpFlippableSLD :: FC.ElemsOf rs '[ET.DemShare, MR.ModelCI] => F.Record rs -> Bool
lpFlippableSLD r =
  let ppl = r ^. ET.demShare
      dpl = MT.ciMid $ r ^. MR.modelCI
  in ppl >= 0.45 && ppl < 0.5 && dpl >= 0.5

lastPush :: (K.KnitEffects r, BRCC.CacheEffects r) => K.Sem r ()
lastPush = do
  let swingStatesL = ["AZ","NV","MI","WI","PA","NC","GA","TX","FL"]
  upperOnlyMap <- BRS.stateUpperOnlyMap
  singleCDMap <- BRS.stateSingleCDMap
  let  turnoutConfig = MC.ActionConfig survey (MC.ModelConfig aggregation alphaModel (contramap F.rcast dmr))
       prefConfig = MC.PrefConfig (DP.Validated DP.Both) (MC.ModelConfig aggregation alphaModel (contramap F.rcast dmr))
       analyzeOneBase s = K.logLE K.Info ("Working on " <> s) >> BSL.analyzeStateGaba BSL.Modeled turnoutConfig Nothing prefConfig Nothing upperOnlyMap singleCDMap s
       lpFilter = F.filterFrame (\r -> lpInCompetitiveCD r && lpFlippableSLD r)
  swingStateAnalysisBase_C <- fmap (fmap mconcat . sequenceA) $ traverse analyzeOneBase swingStatesL
  K.ignoreCacheTime swingStateAnalysisBase_C >>= writeModeled "lastPush_Base" . fmap F.rcast . lpFilter
  -- now with a single scenario
  -- Dobbs effect which boosts turnout of women by 5% and D pref by 2.5%
  -- losing ground with Hispanic and Black voters by 5%
  -- picking up 2% among White non-college
  let dobbsBoostF x r = if (r ^. DT.sexC == DT.Female) then MR.adjustP x else id
--      dobbsTurnoutS = MR.SimpleScenario "DobbsT" $ dobbsBoostF 0.05
--      dobbsPrefS = MR.SimpleScenario "DobbsP" dobbsBoostF 0.025
      reCoalitionF r = case (r ^. DT.race5C) of
        DT.R5_Hispanic -> MR.adjustP (-0.05)
        DT.R5_Black -> MR.adjustP (-0.05)
        DT.R5_WhiteNonHispanic -> if (r ^. DT.education4C /= DT.E4_CollegeGrad) then MR.adjustP 0.02 else id
        _ -> id
      lpTurnoutS = MR.SimpleScenario "LastPustT" $ dobbsBoostF 0.05
      lpPrefS = MR.SimpleScenario "LastPushP" $ \r -> dobbsBoostF 0.025 r . reCoalitionF r
      analyzeOneS s = K.logLE K.Info ("Working on " <> s) >> BSL.analyzeStateGaba BSL.Modeled turnoutConfig (Just lpTurnoutS) prefConfig (Just lpPrefS) upperOnlyMap singleCDMap s
  swingStateAnalysisS_C <- fmap (fmap mconcat . sequenceA) $ traverse analyzeOneS swingStatesL
  K.ignoreCacheTime swingStateAnalysisS_C >>= writeModeled "lastPush_Scenario" . fmap F.rcast . lpFilter



gabaFull :: (K.KnitEffects r, BRCC.CacheEffects r) => K.Sem r ()
gabaFull = do
  allStatesL <- filter (\sa -> (sa `notElem` ["DC"]))
                . fmap (view GT.stateAbbreviation)
                . filter ((< 60) . view GT.stateFIPS)
                . FL.fold FL.list
                <$> (K.ignoreCacheTimeM $ BRS.stateAbbrCrosswalkLoader)
  upperOnlyMap <- BRS.stateUpperOnlyMap
  singleCDMap <- BRS.stateSingleCDMap
  let  turnoutConfig = MC.ActionConfig survey (MC.ModelConfig aggregation alphaModel (contramap F.rcast dmr))
       prefConfig = MC.PrefConfig (DP.Validated DP.Both) (MC.ModelConfig aggregation alphaModel (contramap F.rcast dmr))
       analyzeOne s = K.logLE K.Info ("Working on " <> s) >> BSL.analyzeStateGaba BSL.Modeled turnoutConfig Nothing prefConfig Nothing upperOnlyMap singleCDMap s
  allStateAnalysis_C <- fmap (fmap mconcat . sequenceA) $ traverse analyzeOne allStatesL
  K.ignoreCacheTime allStateAnalysis_C >>= writeModeled "modeled" . fmap F.rcast

writeModeled :: (K.KnitEffects r)
             => Text
             -> F.FrameRec [GT.StateAbbreviation, GT.DistrictTypeC, GT.DistrictName,ET.DemShare, ET.RawPVI, MR.ModelCI, CE.DistCategory, BSL.CD, DO.Overlap, BSL.CDPPL]
             -> K.Sem r ()
writeModeled csvName modeledEv = do
  let wText = FCSV.formatTextAsIs
      printNum n m = PF.printf ("%" <> show n <> "." <> show m <> "g")
      wPrintf' :: (V.KnownField t, V.Snd t ~ Double) => Int -> Int -> (Double -> Double) -> V.Lift (->) V.ElField (V.Const Text) t
      wPrintf' n m f = FCSV.liftFieldFormatter $ toText @String . printNum n m . f
      wDPL :: (V.KnownField t, V.Snd t ~ MT.ConfidenceInterval) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
      wDPL n m = FCSV.liftFieldFormatter
                 $ toText @String . \ci -> printNum n m (100 * MT.ciMid ci)
      wModeled :: (V.KnownField t, V.Snd t ~ MT.ConfidenceInterval) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
      wModeled n m = FCSV.liftFieldFormatter
                     $ toText @String . \ci -> printNum n m (100 * MT.ciMid ci) <> ","
      wOrMissing :: (V.KnownField t, V.Snd t ~ FOM.OrMissing a) => (a -> Text) -> Text -> V.Lift (->) V.ElField (V.Const Text) t
      wOrMissing ifPresent ifMissing =  FCSV.liftFieldFormatter $ \case
        FOM.Present a -> ifPresent a
        FOM.Missing -> ifMissing

      formatModeled = FCSV.formatTextAsIs
                       V.:& formatDistrictType
                       V.:& FCSV.formatTextAsIs
                       V.:& wPrintf' 2 0 (* 100)
                       V.:& wPrintf' 2 0 (* 100)
                       V.:& wDPL 2 0
                       V.:& FCSV.formatTextAsIs
                       V.:& wOrMissing show "At Large"--FCSV.formatWithShow
                       V.:& wPrintf' 2 0 (* 100)
                       V.:& wOrMissing (toText @String . printNum 2 0 . (* 100)) "N/A" --wPrintf' 2 0 (* 100)
                       V.:& V.RNil
      newHeaderMap = M.fromList [("StateAbbreviation", "State")
                                , ("DistrictTypeC", "District Type")
                                , ("DistrictName", "District Name")
                                , ("DemShare", "Historical D Share % (Dave's Redistricting)")
                                , ("RawPVI" , "Historical PVI")
                                , ("ModelCI", "Demographic D % (BlueRipple)")
                                , ("DistCategory", "BlueRipple Comment")
                                , ("CongressionalDistrict","Congressional District")
                                , ("Overlap", "% SLD in CD")
                                , ("CDPPL", "CD Historical D% (Dave's Redistricting)")
                                ]
  K.liftKnit @IO
    $ FCSV.writeLines (toString $ "../../forGaba/" <> csvName <> ".csv")
    $ FCSV.streamSV' @_ @(StreamlyStream Stream) newHeaderMap formatModeled ","
    $ FCSV.foldableToStream modeledEv

formatDistrictType :: (V.KnownField t, V.Snd t ~ GT.DistrictType) => V.Lift (->) V.ElField (V.Const Text) t
formatDistrictType = FCSV.liftFieldFormatter $ \case
  GT.StateUpper -> "Upper House"
  GT.StateLower -> "Lower House"
  GT.Congressional -> "Error: Congressional District!"

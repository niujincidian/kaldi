#!/bin/bash

set -e

# based on run_tdnn_7b.sh in the swbd recipe

# configs for 'chain'
affix=
stage=7 # assuming you already ran the xent systems
train_stage=-10
get_egs_stage=-10
dir=exp/chain/tdnn_7b
decode_iter=

# training options
num_epochs=4
remove_egs=false
common_egs_dir=
num_data_reps=3


min_seg_len=
frames_per_eg=150
# End configuration section.
echo "$0 $@"  # Print the command line for logging

. ./cmd.sh
. ./path.sh
. ./utils/parse_options.sh

if ! cuda-compiled; then
  cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.
EOF
fi

dir=${dir}${affix:+_$affix}
ali_dir=exp/tri5a_rvb_ali
treedir=exp/chain/tri6_tree_11000
lang=data/lang_chain


# The iVector-extraction and feature-dumping parts are the same as the standard
# nnet3 setup, and you can skip them by setting "--stage 8" if you have already
# run those things.
local/nnet3/run_ivector_common.sh --stage $stage --num-data-reps 3|| exit 1;

if [ $stage -le 7 ]; then
  # Create a version of the lang/ directory that has one state per phone in the
  # topo file. [note, it really has two states.. the first one is only repeated
  # once, the second one has zero or more repeats.]
  rm -rf $lang
  cp -r data/lang $lang
  silphonelist=$(cat $lang/phones/silence.csl) || exit 1;
  nonsilphonelist=$(cat $lang/phones/nonsilence.csl) || exit 1;
  # Use our special topology... note that later on may have to tune this
  # topology.
  steps/nnet3/chain/gen_topo.py $nonsilphonelist $silphonelist >$lang/topo
fi

if [ $stage -le 8 ]; then
  # Build a tree using our new topology.
  # we build the tree using clean features (data/train) rather than
  # the augmented features (data/train_rvb) to get better alignments

  steps/nnet3/chain/build_tree.sh --frame-subsampling-factor 3 \
      --leftmost-questions-truncate -1 \
      --cmd "$train_cmd" 11000 data/train $lang exp/tri5a $treedir
fi

if [ -z $min_seg_len ]; then
  min_seg_len=$(python -c "print ($frames_per_eg+5)/100.0")
fi

if [ $stage -le 9 ]; then
  rm -rf data/train_rvb_min${min_seg_len}_hires
  steps/cleanup/combine_short_segments.py --minimum-duration $min_seg_len \
    --input-data-dir data/train_rvb_hires \
    --output-data-dir data/train_rvb_min${min_seg_len}_hires

  #extract ivectors for the new data
  steps/online/nnet2/copy_data_dir.sh --utts-per-spk-max 2 \
    data/train_rvb_min${min_seg_len}_hires data/train_rvb_min${min_seg_len}_hires_max2
  ivectordir=exp/nnet3/ivectors_train_min${min_seg_len}
  if [[ $(hostname -f) == *.clsp.jhu.edu ]]; then # this shows how you can split across multiple file-systems.
    utils/create_split_dir.pl /export/b0{1,2,3,4}/$USER/kaldi-data/egs/aspire/s5/$ivectordir/storage $ivectordir/storage
  fi

  steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 200 \
    data/train_rvb_min${min_seg_len}_hires_max2 \
    exp/nnet3/extractor $ivectordir || exit 1;

 # combine the non-hires features for alignments/lattices
 rm -rf data/${latgen_train_set}_min${min_seg_len}
  utt_prefix="THISISUNIQUESTRING_"
  spk_prefix="THISISUNIQUESTRING_"
  utils/copy_data_dir.sh --spk-prefix "$spk_prefix" --utt-prefix "$utt_prefix" \
    data/train data/train_temp_for_lats
  steps/cleanup/combine_short_segments.py --minimum-duration $min_seg_len \
                   --input-data-dir data/train_temp_for_lats \
                   --output-data-dir data/train_min${min_seg_len}
fi

if [ $stage -le 10 ]; then
  # Get the alignments as lattices (gives the chain training more freedom).
  # use the same num-jobs as the alignments
  nj=200
  lat_dir=exp/tri5a_min${min_seg_len}_lats
  steps/align_fmllr_lats.sh --nj $nj --cmd "$train_cmd" data/train_min${min_seg_len} \
    data/lang exp/tri5a $lat_dir
  rm -f $lat_dir/fsts.*.gz # save space

  rvb_lat_dir=exp/tri5a_rvb_min${min_seg_len}_lats
  #mkdir -p $rvb_lat_dir/temp/
  #lattice-copy "ark:gunzip -c $lat_dir/lat.*.gz |" ark,scp:$rvb_lat_dir/temp/lats.ark,$rvb_lat_dir/temp/lats.scp

  # copy the lattices for the reverberated data
  rm -f $rvb_lat_dir/temp/combined_lats.scp
  touch $rvb_lat_dir/temp/combined_lats.scp
  for i in `seq 1 $num_data_reps`; do
    cat $rvb_lat_dir/temp/lats.scp | sed -e "s/THISISUNIQUESTRING/rev${i}/g" >> $rvb_lat_dir/temp/combined_lats.scp
  done
  sort -u $rvb_lat_dir/temp/combined_lats.scp > $rvb_lat_dir/temp/combined_lats_sorted.scp

  lattice-copy scp:$rvb_lat_dir/temp/combined_lats_sorted.scp "ark:|gzip -c >$rvb_lat_dir/lat.1.gz" || exit 1;
  echo "1" > $rvb_lat_dir/num_jobs

  # copy other files from original lattice dir
  for f in cmvn_opts final.mdl splice_opts tree; do
    cp $lat_dir/$f $rvb_lat_dir/$f
  done

fi

if [ $stage -le 11 ]; then
  echo "$0: creating neural net configs";

  # create the config files for nnet initialization
  steps/nnet3/tdnn/make_configs.py \
    --self-repair-scale 0.00001 \
    --feat-dir data/train_rvb_hires \
    --ivector-dir exp/nnet3/ivectors_train_min${min_seg_len} \
    --tree-dir $treedir \
    --relu-dim 1024 \
    --splice-indexes "-1,0,1 -1,0,1,2 -3,0,3 -3,0,3 -3,0,3 -6,-3,0 0" \
    --use-presoftmax-prior-scale false \
    --xent-regularize 0.1 \
    --xent-separate-forward-affine true \
    --include-log-softmax false \
    --final-layer-normalize-target 0.5 \
    $dir/configs || exit 1;
fi

if [ $stage -le 12 ]; then
  if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d $dir/egs/storage ]; then
    utils/create_split_dir.pl \
     /export/b0{5,6,7,8}/$USER/kaldi-data/egs/aspire-$(date +'%m_%d_%H_%M')/s5c/$dir/egs/storage $dir/egs/storage
  fi

  touch $dir/egs/.nodelete # keep egs around when that run dies.

  steps/nnet3/chain/train.py --stage $train_stage \
    --egs.dir "$common_egs_dir" \
    --cmd "$decode_cmd" \
    --feat.online-ivector-dir exp/nnet3/ivectors_train_min${min_seg_len} \
    --feat.cmvn-opts "--norm-means=false --norm-vars=false" \
    --chain.xent-regularize 0.1 \
    --chain.leaky-hmm-coefficient 0.1 \
    --chain.l2-regularize 0.00005 \
    --chain.apply-deriv-weights false \
    --chain.lm-opts="--num-extra-lm-states=2000" \
    --egs.stage $get_egs_stage \
    --egs.opts "--frames-overlap-per-eg 0" \
    --egs.chunk-width 150 \
    --trainer.num-chunk-per-minibatch 128 \
    --trainer.frames-per-iter 1500000 \
    --trainer.num-epochs $num_epochs \
    --trainer.optimization.num-jobs-initial 3 \
    --trainer.optimization.num-jobs-final 16 \
    --trainer.optimization.initial-effective-lrate 0.001 \
    --trainer.optimization.final-effective-lrate 0.0001 \
    --trainer.max-param-change 2.0 \
    --cleanup.remove-egs $remove_egs \
    --feat-dir data/train_rvb_min${min_seg_len}_hires \
    --tree-dir $treedir \
    --lat-dir exp/tri5a_rvb_min${min_seg_len}_lats \
    --dir $dir  || exit 1;
fi

if [ $stage -le 13 ]; then
  # Note: it might appear that this $lang directory is mismatched, and it is as
  # far as the 'topo' is concerned, but this script doesn't read the 'topo' from
  # the lang directory.
  utils/mkgraph.sh --self-loop-scale 1.0 data/lang_pp_test $dir $dir/graph_pp
fi

#%WER 27.8 | 2120 27217 | 78.2 13.6 8.2 6.0 27.8 75.9 | -0.613 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iterfinal_pp_fg/score_9/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 0 --decode-num-jobs 200 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;

exit 0;

# %WER 32.7 | 2120 27222 | 73.6 15.3 11.2 6.3 32.7 78.5 | -0.530 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter100_pp_fg/score_9/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 100 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;

# %WER 30.4 | 2120 27211 | 74.8 12.7 12.5 5.1 30.4 77.0 | -0.458 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter200_pp_fg/score_10/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 200 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 29.1 | 2120 27216 | 76.6 13.8 9.6 5.7 29.1 76.8 | -0.527 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter300_pp_fg/score_9/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 300 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 28.8 | 2120 27211 | 77.0 13.8 9.2 5.8 28.8 76.3 | -0.587 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter400_pp_fg/score_9/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 400 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 28.7 | 2120 27218 | 77.1 13.8 9.1 5.8 28.7 77.0 | -0.566 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter500_pp_fg/score_9/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 500 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 28.5 | 2120 27210 | 77.5 13.9 8.7 6.0 28.5 76.1 | -0.596 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter600_pp_fg/score_9/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 600 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 28.2 | 2120 27217 | 77.0 12.4 10.6 5.2 28.2 75.8 | -0.540 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter700_pp_fg/score_10/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 700 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 28.4 | 2120 27218 | 77.6 13.6 8.8 6.0 28.4 76.3 | -0.607 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter800_pp_fg/score_9/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 800 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 28.2 | 2120 27208 | 77.4 12.6 10.0 5.6 28.2 76.6 | -0.555 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter900_pp_fg/score_10/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 900 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 27.8 | 2120 27214 | 78.0 13.5 8.5 5.9 27.8 75.9 | -0.631 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter1000_pp_fg/score_9/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 1000 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 27.9 | 2120 27216 | 77.6 13.0 9.4 5.5 27.9 76.1 | -0.544 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter1200_pp_fg/score_10/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 1200 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 27.8 | 2120 27216 | 77.4 13.1 9.5 5.3 27.8 75.7 | -0.615 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter1300_pp_fg/score_9/penalty_0.25/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 1300 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 27.7 | 2120 27220 | 78.1 13.6 8.3 5.8 27.7 75.1 | -0.569 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter1400_pp_fg/score_9/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 1400 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;
# %WER 27.7 | 2120 27217 | 78.1 13.6 8.3 5.9 27.7 75.1 | -0.605 | exp/chain/tdnn_7b/decode_dev_aspire_whole_uniformsegmented_win10_over5_v6_200jobs_iter1500_pp_fg/score_9/penalty_0.0/ctm.filt.filt.sys
  local/chain/prep_test_aspire.sh --stage 4 --decode-num-jobs 200 --iter 1500 --affix "v6_200jobs" \
   --sub-speaker-frames 6000 --window 10 --overlap 5 --max-count 75 --pass2-decode-opts "--min-active 1000" \
   --ivector-scale 0.75  --tune-hyper true dev_aspire data/lang exp/chain/tdnn_7b || exit 1;

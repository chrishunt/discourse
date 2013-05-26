class PostMove
  attr_reader :original_topic, :destination_topic, :user, :ids

  def initialize(original_topic, user, ids)
    @original_topic = original_topic
    @user = user
    @ids = ids
  end

  def to_topic(id)
    Topic.transaction do
      move_posts_to Topic.find_by_id(id)
    end
  end

  def to_new_topic(title)
    Topic.transaction do
      move_posts_to Topic.create!(
        user: user,
        title: title,
        category: original_topic.category
      )
    end
  end

  private

  def move_posts_to(topic)
    @destination_topic = topic

    move_posts_to_destination_topic
    destination_topic
  end

  def move_posts_to_destination_topic
    ensure_user_can_see_topic do
      move_each_post
      notify_users_that_posts_have_moved
      update_statistics
    end
  end

  def ensure_user_can_see_topic
    Guardian.new(user).ensure_can_see! destination_topic
    yield
  end

  def move_each_post
    posts.each { |post| post.is_first_post? ? copy(post) : move(post) }
  end

  def copy(post)
    PostCreator.create(
      post.user,
      raw: post.raw,
      topic_id: destination_topic.id,
      acting_user: user
    )
  end

  def move(post)
    @first_post_number_moved ||= post.post_number

    Post.update_all(
      [
        ['post_number = :post_number',
         'topic_id    = :topic_id',
         'sort_order  = :post_number'
        ].join(', '),
        post_number: next_post_number,
        topic_id: destination_topic.id
      ],
      id: post.id,
      topic_id: original_topic.id
    )
  end

  def update_statistics
    destination_topic.update_statistics
    original_topic.update_statistics
  end

  def notify_users_that_posts_have_moved
    enqueue_notification_job
    create_moderator_post_in_original_topic
  end

  def enqueue_notification_job
    Jobs.enqueue(
      :notify_moved_posts,
      post_ids: ids,
      moved_by_id: user.id
    )
  end

  def create_moderator_post_in_original_topic
    original_topic.add_moderator_post(
      user,
      I18n.t(
        "move_posts.moderator_post",
        count: ids.count,
        topic_link: "[#{destination_topic.title}](#{destination_topic.url})"
      ),
      post_number: @first_post_number_moved
    )
  end

  def next_post_number
    destination_topic.max_post_number + 1
  end

  def posts
    @posts ||= begin
      Post.where(id: ids).order(:created_at).tap do |posts|
        raise Discourse::InvalidParameters.new(:ids) if posts.empty?
      end
    end
  end
end
